import AVFAudio
import Foundation
import Testing
@testable import LiveMinutesKit

@Suite("認識結果からイベントへの変換")
struct TranscriptEventMapperTests {
    @Test("未確定の結果はそのまま volatile になる")
    func volatileResult() {
        let event = TranscriptEventMapper.event(text: "じゃあ", isFinal: false, start: 0, end: 1, lastEnd: 0)
        #expect(event == .volatile("じゃあ"))
    }

    @Test("確定した結果は時刻つきの区間になる")
    func finalResult() throws {
        let event = TranscriptEventMapper.event(text: "延期しましょう", isFinal: true, start: 12.5, end: 14.0, lastEnd: 10)
        guard case .final(let segment) = try #require(event) else {
            Issue.record("final ではない")
            return
        }
        #expect(segment.text == "延期しましょう")
        #expect(segment.start == 12.5)
        #expect(segment.end == 14.0)
    }

    @Test("空白だけの確定結果は捨てる")
    func emptyFinalIsDropped() {
        #expect(TranscriptEventMapper.event(text: " \n", isFinal: true, start: 0, end: 1, lastEnd: 0) == nil)
    }

    @Test("時刻が有限でなければ直前の終わりに寄せる")
    func nonFiniteTimes() throws {
        let event = TranscriptEventMapper.event(text: "はい", isFinal: true, start: .nan, end: .infinity, lastEnd: 8)
        guard case .final(let segment) = try #require(event) else {
            Issue.record("final ではない")
            return
        }
        #expect(segment.start == 8)
        #expect(segment.end == 8)
    }
}

@Suite("TranscriptBuffer")
struct TranscriptBufferTests {
    @Test("未確定は置き換え、確定で追加して未確定を消す")
    func appliesEvents() {
        var buffer = TranscriptBuffer()
        buffer.apply(.volatile("じゃあ"))
        buffer.apply(.volatile("じゃあリリースは"))
        #expect(buffer.volatileText == "じゃあリリースは")
        #expect(buffer.segments.isEmpty)

        let segment = TranscriptSegment(start: 0, end: 2, text: "じゃあリリースは来週にしましょう")
        buffer.apply(.final(segment))
        #expect(buffer.segments == [segment])
        #expect(buffer.volatileText.isEmpty)

        buffer.apply(.volatile("佐藤さん"))
        buffer.clearVolatile()
        #expect(buffer.volatileText.isEmpty)
        #expect(buffer.segments.count == 1)
    }
}

// MARK: - 画面用モデル

/// 決められたイベントを流す偽の文字起こしエンジン。
actor ScriptedEngine: TranscriptionEngine {
    private let eventsOnStart: [TranscriptEvent]
    private let eventsOnStop: [TranscriptEvent]
    private let prepareError: (any Error)?
    private let startError: (any Error)?
    private var continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        eventsOnStart: [TranscriptEvent] = [],
        eventsOnStop: [TranscriptEvent] = [],
        prepareError: (any Error)? = nil,
        startError: (any Error)? = nil
    ) {
        self.eventsOnStart = eventsOnStart
        self.eventsOnStop = eventsOnStop
        self.prepareError = prepareError
        self.startError = startError
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        prepareCount += 1
        progress(0.5)
        if let prepareError { throw prepareError }
    }

    func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        startCount += 1
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptEvent.self)
        eventsOnStart.forEach { continuation.yield($0) }
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopCount += 1
        eventsOnStop.forEach { continuation?.yield($0) }
        continuation?.finish()
        continuation = nil
    }

    /// 録音中の失敗を再現する。
    func failDuringRecording(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

struct FixedPermission: MicrophonePermission {
    let granted: Bool
    func requestAccessIfNeeded() async -> Bool { granted }
}

@MainActor
@Suite("LiveTranscriptionModel")
struct LiveTranscriptionModelTests {
    let source = FakeAudioSource(chunks: [])

    @Test("開始で録音中になり、停止で最後の確定まで受け取ってから待機に戻る")
    func startAndStop() async {
        let first = TranscriptSegment(start: 0, end: 2, text: "おはようございます")
        let last = TranscriptSegment(start: 2, end: 4, text: "始めましょう")
        let engine = ScriptedEngine(
            eventsOnStart: [.volatile("おはよう"), .final(first), .volatile("始め")],
            eventsOnStop: [.final(last)]
        )
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        #expect(model.state == .recording)
        #expect(model.problem == nil)

        await model.stop()
        #expect(model.state == .idle)
        #expect(model.transcript.segments == [first, last])
        #expect(model.transcript.volatileText.isEmpty)
        #expect(await engine.stopCount == 1)
    }

    @Test("準備は最初の開始で1回だけ行う")
    func preparesOnce() async {
        let engine = ScriptedEngine()
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        await model.stop()
        await model.start()
        await model.stop()

        #expect(await engine.prepareCount == 1)
        #expect(await engine.startCount == 2)
    }

    @Test("新しく開始すると、前回の文字起こしは消える")
    func restartClearsTranscript() async {
        let engine = ScriptedEngine(eventsOnStart: [.final(TranscriptSegment(start: 0, end: 1, text: "一回目"))])
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        await model.stop()
        #expect(model.transcript.segments.count == 1)

        // ScriptedEngine は開始のたびに同じ1件を流す。前回分が残っていれば2件になる。
        await model.start()
        await model.stop()
        #expect(model.transcript.segments.count == 1)
    }

    @Test("マイクの許可がなければ、エンジンを始めずに案内を出す")
    func permissionDenied() async {
        let engine = ScriptedEngine()
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: false))

        await model.start()
        #expect(model.state == .idle)
        #expect(model.problem == .microphoneDenied)
        #expect(await engine.prepareCount == 0)
        #expect(await engine.startCount == 0)
    }

    @Test("ロケール非対応とモデルのダウンロード失敗は、区別できる問題になる", arguments: [
        (TranscriptionError.unsupportedLocale("ja-JP"), LiveTranscriptionModel.Problem.unsupportedLocale),
        (TranscriptionError.modelDownloadFailed("offline"), LiveTranscriptionModel.Problem.modelDownloadFailed),
        (TranscriptionError.transcriberUnavailable, LiveTranscriptionModel.Problem.transcriberUnavailable),
    ])
    func prepareFailures(error: TranscriptionError, expected: LiveTranscriptionModel.Problem) async {
        let engine = ScriptedEngine(prepareError: error)
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        #expect(model.state == .idle)
        #expect(model.problem == expected)
        #expect(await engine.startCount == 0)
    }

    @Test("開始時にマイクが見つからなければ、案内を出して待機に戻る")
    func noInputDeviceOnStart() async {
        let engine = ScriptedEngine(startError: AudioSourceError.noInputDevice)
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        #expect(model.state == .idle)
        #expect(model.problem == .noInputDevice)
    }

    @Test("録音中に認識が失敗したら、問題を表示して待機に戻る")
    func failureDuringRecording() async {
        let engine = ScriptedEngine(eventsOnStart: [.volatile("途中")])
        let model = LiveTranscriptionModel(engine: engine, source: source, permission: FixedPermission(granted: true))

        await model.start()
        await engine.failDuringRecording(AudioSourceError.noInputDevice)
        await model.waitForEvents()

        #expect(model.state == .idle)
        #expect(model.problem == .noInputDevice)
        #expect(model.transcript.volatileText.isEmpty)
    }
}
