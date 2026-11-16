import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import LiveMinutesKit

/// Whisper（ローカル）での書き起こしのテスト（Phase 4D）。モデルはダウンロードせず、偽の書き起こしを使う。
@Suite("Whisper の区切り")
struct WhisperChunkerTests {
    static let rate = 16_000.0

    static func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
    }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    @Test("声のあとに 0.6 秒の無音が続いたら区切る。時刻は流し込んだ音声の累積時間")
    func cutsOnSilence() {
        var chunker = WhisperChunker()
        var chunks = chunker.append(Self.silence(1.0))
        #expect(chunks.isEmpty)
        chunks = chunker.append(Self.tone(2.0) + Self.silence(0.7))
        #expect(chunks.count == 1)
        let chunk = chunks.first
        // 先頭の無音は 0.2〜0.4 秒だけ残し、言い始めの直前から含める。
        #expect((chunk?.start ?? 0) >= 0.55 && (chunk?.start ?? 0) <= 0.85)
        // 区切るのは無音が 0.6 秒続いた時点（声の終わり 3.0 秒 + 0.6 秒）。
        #expect(abs((chunk?.end ?? 0) - 3.6) < 0.11)
        // 区切りの後に流した無音は、次の区切りの先頭として少しだけ残る。
        #expect(chunker.bufferedDuration < 0.5)
        #expect(chunker.isInSpeech == false)
    }

    @Test("無音がなくても、15 秒で区切る")
    func cutsAtMaxDuration() {
        var chunker = WhisperChunker()
        let chunks = chunker.append(Self.tone(16))
        #expect(chunks.count == 1)
        #expect(abs((chunks.first?.end ?? 0) - (chunks.first?.start ?? 0) - 15) < 0.11)
        #expect(chunker.isInSpeech)
    }

    @Test("声のない区間と、短すぎる音（咳など）は区切りにしない")
    func ignoresSilenceAndShortNoise() {
        var chunker = WhisperChunker()
        #expect(chunker.append(Self.silence(5)).isEmpty)
        #expect(chunker.append(Self.tone(0.1) + Self.silence(1)).isEmpty)
        #expect(chunker.flush() == nil)
    }

    @Test("100ms に満たない端数も、次に足した音声とつないで扱い、停止時は残りを最後の区切りにする")
    func remainderAndFlush() {
        var chunker = WhisperChunker()
        let audio = Self.tone(1.0)
        // 端数の出る長さで分けて流す。
        _ = chunker.append(Array(audio[0..<1234]))
        _ = chunker.append(Array(audio[1234...]))
        let last = chunker.flush()
        #expect(last != nil)
        #expect(abs((last?.end ?? 0) - 1.0) < 0.001)
        #expect(last?.samples.count == audio.count)
    }
}

/// 偽の書き起こし。届いた音声の長さを記録し、決まった文を返す。
actor FakeWhisperTranscriber: WhisperTranscriber {
    private(set) var calls: [(count: Int, language: String)] = []
    var failure: (any Error)?
    var text: String

    init(text: String = "こんにちは") {
        self.text = text
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        calls.append((samples.count, language))
        if let failure { throw failure }
        return text
    }

    func setFailure(_ error: (any Error)?) { failure = error }
    func setText(_ value: String) { text = value }
}

@Suite("Whisper（ローカル）のエンジン")
struct WhisperLocalEngineTests {
    static func buffer(_ samples: [Float]) -> AudioChunk {
        let format = WhisperLocalEngine.inputFormat!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() { buffer.floatChannelData![0][index] = value }
        return AudioChunk(buffer: buffer)
    }

    private func makeEngine(_ transcriber: FakeWhisperTranscriber, modelName: String = "small", loads: LoadCounter = LoadCounter()) -> WhisperLocalEngine {
        WhisperLocalEngine(modelName: { modelName }, load: { name in
            await loads.record(name)
            return transcriber
        })
    }

    actor LoadCounter {
        private(set) var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    private func collect(_ events: AsyncThrowingStream<TranscriptEvent, any Error>) async throws -> [TranscriptEvent] {
        var result: [TranscriptEvent] = []
        for try await event in events { result.append(event) }
        return result
    }

    @Test("16kHz・モノラル・Float32 で受け取り、区切りごとに確定を流す。言語はロケールから決める")
    func finalsPerChunk() async throws {
        let transcriber = FakeWhisperTranscriber()
        let engine = makeEngine(transcriber)
        let audio = WhisperChunkerTests.tone(1.5) + WhisperChunkerTests.silence(0.8) + WhisperChunkerTests.tone(1.0)
        let source = FakeAudioSource(chunks: [Self.buffer(audio)], finishWhenDrained: true)

        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        let events = try await collect(engine.start(source: source))
        let finals = events.compactMap { event -> TranscriptSegment? in
            if case .final(let segment) = event { return segment }
            return nil
        }
        #expect(finals.count == 2)
        #expect(finals.allSatisfy { $0.text == "こんにちは" })
        #expect(finals[0].end <= finals[1].start)
        let format = try #require(await source.requestedFormats.first)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(await transcriber.calls.allSatisfy { $0.language == "ja" })
    }

    @Test("区切りの途中は約2秒ごとに途中結果を出す（書き起こしが空いているときだけ）")
    func partials() async throws {
        let transcriber = FakeWhisperTranscriber(text: "途中")
        let engine = makeEngine(transcriber)
        // 5 秒続く声を 0.5 秒ずつ流す。
        let pieces = stride(from: 0, to: 10, by: 1).map { _ in Self.buffer(WhisperChunkerTests.tone(0.5)) }
        let source = FakeAudioSource(chunks: pieces, finishWhenDrained: true)
        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        let events = try await collect(engine.start(source: source))
        #expect(events.contains(.volatile("途中")))
        // 停止時（ストリームの終わり）に残りを確定する。
        if case .final = events.last {} else { Issue.record("最後は確定であるべき") }
    }

    @Test("停止すると、残りを最後の区切りとして書き起こしてから終える")
    func stopFlushes() async throws {
        let transcriber = FakeWhisperTranscriber(text: "最後")
        let engine = makeEngine(transcriber)
        let source = FakeAudioSource(chunks: [Self.buffer(WhisperChunkerTests.tone(1.0))])
        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        let stream = try await engine.start(source: source)
        let collecting = Task { try await collect(stream) }
        try await Task.sleep(for: .milliseconds(100))
        await engine.stop()
        let events = try await collecting.value
        #expect(events.last == .final(TranscriptSegment(id: Self.finalID(events), start: 0, end: 1.0, text: "最後")))
    }

    private static func finalID(_ events: [TranscriptEvent]) -> UUID {
        if case .final(let segment) = events.last { return segment.id }
        return UUID()
    }

    @Test("書き起こしに失敗したら、マイクを止め、ストリームをエラーで終える")
    func failure() async throws {
        let transcriber = FakeWhisperTranscriber()
        await transcriber.setFailure(TestTranscribeFailure())
        let engine = makeEngine(transcriber)
        let source = FakeAudioSource(chunks: [Self.buffer(WhisperChunkerTests.tone(1.0) + WhisperChunkerTests.silence(0.8))])
        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        let stream = try await engine.start(source: source)
        await #expect(throws: TranscriptionError.whisperFailed("TestTranscribeFailure")) { _ = try await collect(stream) }
        // 止めた後は、もう一度開始できる（後始末が済んでいる）。
        let again = try await engine.start(source: FakeAudioSource(chunks: [], finishWhenDrained: true))
        _ = try await collect(again)
    }

    @Test("モデルがなければ準備で失敗する。モデル名が変わったら読み込み直し、同じなら読み込まない")
    func loading() async throws {
        let missing = WhisperLocalEngine(modelName: { "small" }, load: { _ in throw TranscriptionError.whisperModelMissing })
        await #expect(throws: TranscriptionError.whisperModelMissing) {
            try await missing.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        }

        let loads = LoadCounter()
        let name = Mutex("small")
        let transcriber = FakeWhisperTranscriber()
        let engine = WhisperLocalEngine(modelName: { name.withLock { $0 } }, load: { model in
            await loads.record(model)
            return transcriber
        })
        try await engine.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await engine.prepare(locale: Locale(identifier: "en-US")) { _ in }
        #expect(await loads.names == ["small"])
        name.withLock { $0 = "base" }
        try await engine.prepare(locale: Locale(identifier: "en-US")) { _ in }
        #expect(await loads.names == ["small", "base"])
        #expect(WhisperLocalEngine.languageCode(for: Locale(identifier: "en-US")) == "en")
    }

    @Test("モデルの保存先: ダウンロードしていなければ、ないと答え、読み込みは「モデルがない」で失敗する")
    func modelStoreWithoutDownload() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let store = WhisperModelStore(baseURL: dir.url)
        #expect(await store.isDownloaded("small") == false)
        try await store.delete("small")
        await #expect(throws: TranscriptionError.whisperModelMissing) { _ = try await store.loadTranscriber("small") }
        #expect(WhisperModelStore.variants.map(\.id).contains(WhisperModelStore.defaultVariant))
    }
}

@Suite("書き起こしの方式の切り替え")
struct SwitchingTranscriptionEngineTests {
    @MainActor
    final class KindBox {
        var kind: TranscriptionEngineKind = .apple
    }

    @Test("方式は開始のたびに読む。まだ準備していない方式なら、前回のロケールで準備してから開始する")
    @MainActor
    func switchesPerStart() async throws {
        let box = KindBox()
        let apple = ScriptedEngine(eventsPerStart: [[], []])
        let transcriber = FakeWhisperTranscriber()
        let loads = WhisperLocalEngineTests.LoadCounter()
        let whisper = WhisperLocalEngine(modelName: { "small" }, load: { name in
            await loads.record(name)
            return transcriber
        })
        let engine = SwitchingTranscriptionEngine(kind: { box.kind }, apple: apple, whisper: whisper)

        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }
        _ = try await engine.start(source: FakeAudioSource(chunks: []))
        await engine.stop()
        #expect(await loads.names.isEmpty)

        box.kind = .whisperLocal
        _ = try await engine.start(source: FakeAudioSource(chunks: []))
        await engine.stop()
        #expect(await loads.names == ["small"])
    }
}

struct TestTranscribeFailure: Error {}
