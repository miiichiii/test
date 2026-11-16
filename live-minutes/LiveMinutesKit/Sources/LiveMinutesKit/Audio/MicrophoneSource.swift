import AVFAudio
import Foundation
import os

/// マイク入力（AVAudioEngine の inputNode に付けた tap）による `AudioSource`。
///
/// - tap のコールバックでは「変換」「レベル計算」「ストリームへの受け渡し」だけを行う（`TapProcessor`）
/// - 入力デバイスが変わると（`AVAudioEngineConfigurationChange`）、AVAudioEngine ごと作り直して録音を続ける。
///   音声のストリームは切らない
/// - マイクを選べる（DESIGN.md §4.1「マイクの選択」）。選んだマイクがなければ Mac の設定のマイクで録音し、
///   録音中はデバイスの一覧の変化を聞いて、使うべきマイクが変わったら作り直す
public actor MicrophoneSource: AudioSource {
    public nonisolated let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private var isRunning = false
    private var outputFormat: AVAudioFormat?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?

    private var engine: AVAudioEngine?
    /// エンジンを作るたびに増やす番号。古いエンジンから届いた通知を見分けるために使う。
    private var engineGeneration = 0
    private var configurationObserver: (any NSObjectProtocol)?
    private var configurationSignal: AsyncStream<Int>.Continuation?
    private var configurationTask: Task<Void, Never>?

    /// 選ばれたマイクの UID。nil なら Mac の設定のマイク
    private var preferredUID: String?
    /// 今のエンジンが使っているマイクの UID。nil なら Mac の設定のマイク
    private var activeUID: String?
    /// 作り直しが続きすぎたので、選んだマイクをやめている（選び直すまで）
    private var isPreferredSuppressed = false
    private var rebuildLimiter = RebuildLimiter()
    /// 録音中に、デバイスの一覧の変化を聞く Task
    private var deviceChangesTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Audio")

    /// - Parameter preferredDeviceUID: 使うマイクの UID。nil か空なら Mac の設定のマイク
    public init(preferredDeviceUID: String? = nil) {
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        preferredUID = Self.normalized(preferredDeviceUID)
    }

    /// 使うマイクを選び直す。録音中ならすぐに切り替え、録音していなければ覚えるだけにする
    /// （エンジンを作るとマイクのインジケータが点くため）。
    public func setPreferredDevice(uid: String?) {
        preferredUID = Self.normalized(uid)
        isPreferredSuppressed = false
        rebuildLimiter.reset()
        requestRebuildIfNeeded()
    }

    public func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw AudioSourceError.alreadyRunning }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (signals, signal) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        self.outputFormat = outputFormat
        self.chunkContinuation = chunkContinuation
        self.configurationSignal = signal

        do {
            try startPreferredEngine()
        } catch {
            chunkContinuation.finish()
            signal.finish()
            self.outputFormat = nil
            self.chunkContinuation = nil
            self.configurationSignal = nil
            throw error
        }

        isRunning = true
        // 通知は続けて何度も来ることがあるので、1本の Task で直列に処理する（溜めるのは最新の1件だけ）。
        configurationTask = Task { [weak self] in
            for await generation in signals {
                await self?.handleConfigurationChange(generation: generation)
            }
        }
        // 録音中は、デバイスの一覧の変化を常に聞く（選んだマイクが消えたときに通知が来る保証はないため）。
        let deviceChanges = AudioInputDevices.changes()
        deviceChangesTask = Task { [weak self] in
            for await _ in deviceChanges {
                await self?.requestRebuildIfNeeded()
            }
        }
        return chunks
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        deviceChangesTask?.cancel()
        deviceChangesTask = nil
        configurationTask?.cancel()
        configurationTask = nil
        configurationSignal?.finish()
        configurationSignal = nil
        tearDownEngine()
        chunkContinuation?.finish()
        chunkContinuation = nil
        outputFormat = nil
        levelContinuation.yield(0)
    }

    // MARK: - マイクの選択

    private static func normalized(_ uid: String?) -> String? {
        guard let uid, !uid.isEmpty else { return nil }
        return uid
    }

    /// 今使うべきマイクの UID（つながっていなければ nil）
    private func targetUID() -> String? {
        guard preferredUID != nil, !isPreferredSuppressed else { return nil }
        return InputDeviceSelection.target(
            preferredUID: preferredUID,
            availableUIDs: AudioInputDevices.list().map(\.uid),
            suppressed: isPreferredSuppressed
        )
    }

    /// 今使うべきマイクが、今のエンジンのものと違えば作り直しを頼む（同じなら何もしない。ループを防ぐ）。
    private func requestRebuildIfNeeded() {
        guard isRunning else { return }
        guard InputDeviceSelection.needsRebuild(currentUID: activeUID, targetUID: targetUID()) else { return }
        // 作り直しは、構成の変更の通知と同じ経路で、直列に行う。
        configurationSignal?.yield(engineGeneration)
    }

    // MARK: - AVAudioEngine

    /// 選んだマイクでエンジンを作る。失敗したら、新しいエンジンで Mac の設定のマイクを使う（録音を止めない）。
    private func startPreferredEngine() throws {
        if let uid = targetUID() {
            do {
                try startEngine(deviceUID: uid)
                return
            } catch {
                Self.logger.error("選んだマイクで録音を始められないため、Mac の設定のマイクを使う: \(String(describing: error), privacy: .public)")
            }
        }
        try startEngine(deviceUID: nil)
    }

    /// - Parameter deviceUID: 使うマイクの UID。nil なら Mac の設定のマイク（今までと同じ動作）
    private func startEngine(deviceUID: String?) throws {
        guard let outputFormat, let chunkContinuation else { return }

        let engine = AVAudioEngine()
        // 出力側（mainMixerNode・outputNode）には触らない。voice processing も有効にしない。
        let input = engine.inputNode
        if let deviceUID {
            guard let deviceID = AudioInputDevices.deviceID(forUID: deviceUID) else {
                throw DeviceSelectionError.notConnected
            }
            // 入力形式を読む前に設定する（設定より前に読むと、古い形式が残ることがある）。
            do {
                try input.auAudioUnit.setDeviceID(deviceID)
            } catch {
                throw DeviceSelectionError.setDeviceFailed(String(describing: error))
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        // 0Hz / 0ch のまま installTap すると、Swift で捕まえられない例外になる（AVAudioEngine.h）。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw deviceUID == nil ? AudioSourceError.noInputDevice : DeviceSelectionError.invalidFormat
        }
        if deviceUID != nil {
            // 選んだマイクでは、装置側と出力側の形式が合うかも確かめる（合わないまま tap を付けると、
            // 捕まえられない例外になるか、TapProcessor が全部捨てる）。
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate == inputFormat.sampleRate,
                  hardwareFormat.channelCount == inputFormat.channelCount else {
                throw DeviceSelectionError.invalidFormat
            }
        }

        let processor = TapProcessor(
            inputFormat: inputFormat,
            converter: try StreamingAudioConverter(from: inputFormat, to: outputFormat),
            chunks: chunkContinuation,
            levels: levelContinuation
        )
        // tap の bufferSize の対応範囲は 100〜400ms（AVAudioNode.h）。遅延を抑えるため最小の 100ms にする。
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: Self.makeTapBlock(processor))

        // 開始までの間に来た通知も落とさないよう、observer は engine.start() より前に付ける。
        // （setDeviceID より後に付けるので、設定そのものの通知は受けない。）
        engineGeneration += 1
        let generation = engineGeneration
        let signal = configurationSignal
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            // 通知は内部のキューで届く。ここではエンジンに触らず、どのエンジンの通知かを actor へ知らせるだけにする。
            signal?.yield(generation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineStartFailed(error.localizedDescription)
        }
        configurationObserver = observer
        self.engine = engine
        activeUID = deviceUID
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        activeUID = nil
    }

    /// 入力デバイスの変更に追従する。通知が来た時点でエンジンは止まっているので、エンジンごと作り直す。
    /// マイクの選び直しや、デバイスの一覧の変化による作り直しも、ここを通る。
    /// - Parameter generation: 通知を出したエンジンの番号。今のエンジンのものでなければ無視する
    ///   （作り直しの前に溜まった通知で、作ったばかりのエンジンをもう一度壊さないため）。
    private func handleConfigurationChange(generation: Int) async {
        guard isRunning, generation == engineGeneration else { return }
        // 切り替えの直後は通知が続けて来たり、入力形式が定まっていなかったりするので少し待つ。
        try? await Task.sleep(for: .milliseconds(250))
        // 待っている間に stop（とその後の start）が走った場合は、新しいエンジンに触らない。
        guard isRunning, !Task.isCancelled, generation == engineGeneration else { return }

        // 作り直しが短い間に続きすぎたら、選んだマイクをやめて Mac の設定のマイクに落とす（ループを防ぐ）。
        if rebuildLimiter.record(at: .now), preferredUID != nil, !isPreferredSuppressed {
            isPreferredSuppressed = true
            Self.logger.error("マイクの作り直しが続いたため、選んだマイクをやめて Mac の設定のマイクを使う")
        }

        tearDownEngine()
        levelContinuation.yield(0)

        var attempt = 0
        while isRunning, !Task.isCancelled {
            do {
                try startPreferredEngine()
                Self.logger.info("入力デバイスの変更後、録音を再開した")
                return
            } catch {
                attempt += 1
                if attempt == 1 {
                    Self.logger.error("入力デバイスの変更後に再開できない。再試行する: \(String(describing: error), privacy: .public)")
                }
                // 最初の数回は短い間隔で、その後はデバイスがつながるまで1秒おきに試す。ストリームは開いたままにする。
                let delay: Duration = attempt < 10 ? .milliseconds(500) : .seconds(1)
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// 選んだマイクを使えなかった理由（ログ用。録音は Mac の設定のマイクで続ける）
    private enum DeviceSelectionError: Error, CustomStringConvertible {
        case notConnected
        case setDeviceFailed(String)
        case invalidFormat

        var description: String {
            switch self {
            case .notConnected: "notConnected"
            case .setDeviceFailed(let detail): "setDeviceFailed(\(detail))"
            case .invalidFormat: "invalidFormat"
            }
        }
    }

    /// tap のブロックを作る。`@Sendable` を明示して actor に分離されないようにする
    /// （分離されたクロージャをオーディオのスレッドから呼ぶと、実行時の分離チェックで落ちる）。
    private nonisolated static func makeTapBlock(
        _ processor: TapProcessor
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in processor.process(buffer) }
    }
}

/// tap のコールバックで行う処理。
///
/// ここでは自前のロック、actor への移動、await、ログ出力、ファイル入出力、変換器の生成をしない。
/// 行うのは、変換・レベル計算・AsyncStream への yield の3つだけ。
/// （tap のブロックはリアルタイムの I/O スレッドではなく、メイン以外のスレッドで呼ばれる。
/// yield は内部で短いロックを取るが、DESIGN.md §2 の設計どおりストリームで受け渡す。）
final class TapProcessor: @unchecked Sendable {
    // @unchecked の理由: process は tap のスレッドだけから直列に呼ばれる。フィールドはすべて let で、
    // 中の変換器を触るのもそのスレッドだけ。tap を付け直すときは新しいインスタンスを作るので、共有されない。
    private let inputFormat: AVAudioFormat
    private let converter: StreamingAudioConverter
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let levels: AsyncStream<Float>.Continuation

    init(
        inputFormat: AVAudioFormat,
        converter: StreamingAudioConverter,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation
    ) {
        self.inputFormat = inputFormat
        self.converter = converter
        self.chunks = chunks
        self.levels = levels
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        // 付け直しの直後に古い形式のバッファが来た場合は捨てる。
        guard buffer.format.sampleRate == inputFormat.sampleRate,
              buffer.format.channelCount == inputFormat.channelCount else { return }

        levels.yield(AudioLevel.normalized(rms: AudioLevel.rms(of: buffer)))
        if let converted = try? converter.convert(buffer) {
            chunks.yield(AudioChunk(buffer: converted))
        }
    }
}
