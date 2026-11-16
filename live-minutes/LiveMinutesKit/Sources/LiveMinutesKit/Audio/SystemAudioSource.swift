import AVFAudio
import CoreAudio
import Foundation
import os

/// Mac から出る音（オンライン会議の相手の声など）を取り込む `AudioSource`（Phase 7。DESIGN.md §4.1）。
///
/// Core Audio のプロセス tap（macOS 14.2 以降）で、LiveMinutes 自身を除く全体の出力をステレオで取り込み、
/// tap だけを入れた非公開の集約デバイスを、マイクと同じように入力として読む。
/// - 出力の音は消さない（`muteBehavior = .unmuted`）。tap は非公開（このプロセスだけに見える）
/// - 初めて録音を始めたときに「システムオーディオ録音のみ」の許可を求められる（Info.plist の
///   `NSAudioCaptureUsageDescription`）。拒否された場合は無音が届く
/// - IOProc のコールバックでは、変換とストリームへの受け渡しだけを行う（マイクの tap と同じ方針）
public actor SystemAudioSource: AudioSource {
    public enum SystemAudioError: Error, Equatable, Sendable {
        case tapUnavailable(OSStatus)
        case aggregateDeviceUnavailable(OSStatus)
        case formatUnavailable
        case startFailed(OSStatus)
    }

    /// 入力レベルは出さない（メーターはマイクのものを使う）
    public nonisolated let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "LiveMinutes.SystemAudioSource")

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "SystemAudio")

    public init() {
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        guard chunkContinuation == nil else { throw AudioSourceError.alreadyRunning }
        do {
            return try startCapture(outputFormat: outputFormat)
        } catch {
            tearDown()
            Self.logger.error("Mac 内の音声を取り込めない: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func stop() async {
        tearDown()
    }

    // MARK: - 内部

    private func startCapture(outputFormat: AVAudioFormat) throws -> AsyncStream<AudioChunk> {
        // LiveMinutes 自身の音（あれば）は取り込まない。
        let excluded = Self.ownProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "LiveMinutes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else { throw SystemAudioError.tapUnavailable(tapStatus) }
        tapID = tap

        guard let tapUID = Self.stringProperty(tap, selector: kAudioTapPropertyUID),
              let tapFormat = Self.tapFormat(tap) else { throw SystemAudioError.formatUnavailable }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveMinutes Mac Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw SystemAudioError.aggregateDeviceUnavailable(aggregateStatus)
        }
        aggregateID = aggregate

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let processor = SystemAudioProcessor(
            format: tapFormat,
            converter: try StreamingAudioConverter(from: tapFormat, to: outputFormat),
            chunks: continuation
        )
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue, Self.makeIOBlock(processor))
        guard createStatus == noErr, let procID else { throw SystemAudioError.startFailed(createStatus) }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else { throw SystemAudioError.startFailed(startStatus) }
        chunkContinuation = continuation
        return chunks
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        chunkContinuation?.finish()
        chunkContinuation = nil
    }

    /// IOProc のブロック。actor に分離されないよう、`@Sendable` の静的な関数で作る。
    private nonisolated static func makeIOBlock(_ processor: SystemAudioProcessor) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in processor.process(inputData) }
    }

    /// このプロセスの Core Audio のプロセスオブジェクト
    private static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr,
              description.mSampleRate > 0, description.mChannelsPerFrame > 0 else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }

    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// IOProc のコールバックで行う処理（変換とストリームへの受け渡しだけ）。
final class SystemAudioProcessor: @unchecked Sendable {
    // @unchecked の理由: process は IOProc の直列キューだけから呼ばれる。フィールドはすべて let で、
    // 中の変換器を触るのもそのキューだけ。開始のたびに新しいインスタンスを作るので、共有されない。
    private let format: AVAudioFormat
    private let converter: StreamingAudioConverter
    private let chunks: AsyncStream<AudioChunk>.Continuation

    init(format: AVAudioFormat, converter: StreamingAudioConverter, chunks: AsyncStream<AudioChunk>.Continuation) {
        self.format = format
        self.converter = converter
        self.chunks = chunks
    }

    func process(_ inputData: UnsafePointer<AudioBufferList>) {
        // コールバックの間だけ有効なメモリを指すバッファ。すぐに変換して、新しいバッファとして渡す。
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0,
              let converted = try? converter.convert(buffer) else { return }
        chunks.yield(AudioChunk(buffer: converted))
    }
}
