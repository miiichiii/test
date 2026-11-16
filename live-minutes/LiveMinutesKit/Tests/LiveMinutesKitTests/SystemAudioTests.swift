import AVFAudio
import Foundation
import Testing
@testable import LiveMinutesKit

/// マイクと Mac 内の音声の混合のテスト（Phase 7）。実際の Mac 内の音声やマイクは使わない。
@Suite("マイクと Mac 内の音声を混ぜる")
struct AudioMixerTests {
    @Test("マイクの長さの分だけ、ためた Mac 内の音声を足す。足りなければその分は足さない")
    func mixesAvailable() {
        var mixer = AudioMixer(maxQueuedSamples: 100)
        mixer.appendSystem([0.1, 0.2])
        #expect(mixer.mix(microphone: [0.5, 0.5, 0.5]) == [0.6, 0.7, 0.5])
        #expect(mixer.systemQueue.isEmpty)
        // Mac 内の音声が届かない（許可を拒否した、など）場合は、マイクのまま。
        #expect(mixer.mix(microphone: [0.3]) == [0.3])
    }

    @Test("足した結果は -1…1 に収める")
    func clips() {
        var mixer = AudioMixer(maxQueuedSamples: 10)
        mixer.appendSystem([0.8, -0.8])
        #expect(mixer.mix(microphone: [0.5, -0.5]) == [1, -1])
    }

    @Test("ためる量に上限があり、超えたら古いものを捨てる（遅れを積み重ねない）")
    func capsQueue() {
        var mixer = AudioMixer(maxQueuedSamples: 3)
        mixer.appendSystem([0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(mixer.systemQueue == [0.3, 0.4, 0.5])
        #expect(mixer.mix(microphone: [0, 0]) == [0.3, 0.4])
        #expect(mixer.systemQueue == [0.5])
    }
}

/// 開始すると必ず失敗するソース（Mac 内の音声を始められない場合）
actor FailingAudioSource: AudioSource {
    nonisolated let levels: AsyncStream<Float> = AsyncStream { $0.finish() }
    private(set) var startCount = 0
    func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        throw SystemAudioSource.SystemAudioError.tapUnavailable(-1)
    }
    func stop() async {}
}

@MainActor
final class SystemAudioToggle {
    var isEnabled = false
}

@Suite("マイクと Mac 内の音声の混合のソース")
struct MixedAudioSourceTests {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func chunk(_ samples: [Float]) -> AudioChunk {
        AudioChunk(buffer: MixedAudioSource.buffer(samples, format: format)!)
    }

    private func collect(_ stream: AsyncStream<AudioChunk>, count: Int) async -> [[Float]] {
        var result: [[Float]] = []
        for await chunk in stream {
            result.append(MixedAudioSource.samples(of: chunk.buffer) ?? [])
            if result.count == count { break }
        }
        return result
    }

    @Test("取り込みがオフなら、マイクをそのまま使い、Mac 内の音声は始めない")
    @MainActor
    func passthroughWhenOff() async throws {
        let toggle = SystemAudioToggle()
        let microphone = FakeAudioSource(chunks: [Self.chunk([0.5, 0.5])])
        let system = FakeAudioSource(chunks: [Self.chunk([0.1, 0.1])])
        let source = MixedAudioSource(microphone: microphone, system: system, isSystemAudioEnabled: { toggle.isEnabled })

        let output = try await source.start(outputFormat: Self.format)
        #expect(await collect(output, count: 1) == [[0.5, 0.5]])
        #expect(await system.startCount == 0)
        #expect(await microphone.requestedFormats.first == Self.format)
        await source.stop()
    }

    @Test("オンなら、両方を浮動小数点・モノラルで受けて足し合わせる")
    @MainActor
    func mixesWhenOn() async throws {
        let toggle = SystemAudioToggle()
        toggle.isEnabled = true
        let microphone = FakeAudioSource(chunks: [])
        let system = FakeAudioSource(chunks: [Self.chunk([0.25, 0.25, 0.25, 0.25])])
        let source = MixedAudioSource(microphone: microphone, system: system, isSystemAudioEnabled: { toggle.isEnabled })

        let output = try await source.start(outputFormat: Self.format)
        #expect(await system.startCount == 1)
        let mixFormat = try #require(await microphone.requestedFormats.first)
        #expect(mixFormat.commonFormat == .pcmFormatFloat32)
        #expect(mixFormat.channelCount == 1)
        // Mac 内の音声が先にたまってから、マイクの音が届く。
        try await Task.sleep(for: .milliseconds(50))
        await microphone.push(Self.chunk([0.5, 0.5, 0.5, 0.5]))
        let mixed = await collect(output, count: 1).joined()
        #expect(mixed.allSatisfy { abs($0 - 0.75) < 0.001 })
        await source.stop()
    }

    @Test("Mac 内の音声を始められなくても、マイクだけで続ける")
    @MainActor
    func microphoneOnlyWhenSystemFails() async throws {
        let toggle = SystemAudioToggle()
        toggle.isEnabled = true
        let microphone = FakeAudioSource(chunks: [Self.chunk([0.4, 0.4])])
        let system = FailingAudioSource()
        let source = MixedAudioSource(microphone: microphone, system: system, isSystemAudioEnabled: { toggle.isEnabled })

        let output = try await source.start(outputFormat: Self.format)
        let samples = await collect(output, count: 1).joined()
        #expect(samples.allSatisfy { abs($0 - 0.4) < 0.001 })
        #expect(await system.startCount == 1)
        await source.stop()
    }
}

@MainActor
@Suite("Mac 内の音声の設定")
struct SystemAudioSettingsTests {
    @Test("既定はオフ。保存して読み直せる")
    func persists() throws {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.captureSystemAudio == false)
        settings.captureSystemAudio = true
        #expect(AppSettings(defaults: defaults).captureSystemAudio)
    }
}
