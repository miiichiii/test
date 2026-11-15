import Foundation
import Testing
@testable import LiveMinutesKit

/// 決められたイベントを流す偽の文字起こしエンジン。
///
/// - 開始のたびに `eventsPerStart` の先頭から1組ずつ流す（尽きたら空）
/// - `stop()` は `eventsOnStop` を流してからストリームを終える。動いていなければ何もしない（実物と同じ）
/// - `holdStop()` を呼ぶと、`releaseStop()` まで `stop()` が戻らない（処理中の操作を試すため）
/// - `holdStart()` を呼ぶと、`releaseStart()` まで `start(source:)` が戻らない
actor ScriptedEngine: TranscriptionEngine {
    private var eventsPerStart: [[TranscriptEvent]]
    private let eventsOnStop: [TranscriptEvent]
    private var prepareError: (any Error)?
    private var startError: (any Error)?
    private var continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var isStopHeld = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStartHeld = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        eventsPerStart: [[TranscriptEvent]] = [],
        eventsOnStop: [TranscriptEvent] = [],
        prepareError: (any Error)? = nil,
        startError: (any Error)? = nil
    ) {
        self.eventsPerStart = eventsPerStart
        self.eventsOnStop = eventsOnStop
        self.prepareError = prepareError
        self.startError = startError
    }

    var isRunning: Bool { continuation != nil }

    private(set) var preparedLocales: [String] = []

    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        prepareCount += 1
        preparedLocales.append(locale.identifier(.bcp47))
        progress(0.5)
        if let prepareError { throw prepareError }
    }

    func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        startCount += 1
        if isStartHeld {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptEvent.self)
        let events = eventsPerStart.isEmpty ? [] : eventsPerStart.removeFirst()
        events.forEach { continuation.yield($0) }
        self.continuation = continuation
        return stream
    }

    func stop() async {
        guard let continuation else { return }
        self.continuation = nil
        stopCount += 1
        if isStopHeld {
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        eventsOnStop.forEach { continuation.yield($0) }
        continuation.finish()
    }

    func setPrepareError(_ error: (any Error)?) {
        prepareError = error
    }

    func setStartError(_ error: (any Error)?) {
        startError = error
    }

    /// 録音中に流すイベントを足す。
    func emit(_ event: TranscriptEvent) {
        continuation?.yield(event)
    }

    /// 録音中の失敗を再現する（実物と同じく、ストリームをエラーで終えて止まる）。
    func failDuringRecording(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    /// 停止操作なしに、エラーなしでストリームが終わる場合を再現する。
    func finishWithoutError() {
        continuation?.finish()
        continuation = nil
    }

    func holdStart() {
        isStartHeld = true
    }

    func releaseStart() {
        isStartHeld = false
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }

    func holdStop() {
        isStopHeld = true
    }

    func releaseStop() {
        isStopHeld = false
        stopWaiters.forEach { $0.resume() }
        stopWaiters = []
    }
}

struct FixedPermission: MicrophonePermission {
    let granted: Bool
    func requestAccessIfNeeded() async -> Bool { granted }
}

/// 手で進める時計。
@MainActor
final class FakeClock: SessionClock {
    var date: Date
    var time: TimeInterval = 1000

    init(date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = date
    }

    func now() -> Date { date }
    func uptime() -> TimeInterval { time }

    func advance(_ seconds: TimeInterval) {
        time += seconds
        date = date.addingTimeInterval(seconds)
    }
}

/// テスト用の一時フォルダ。使い終わったら `remove()` で消す。
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "LiveMinutesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 条件が満たされるまで待つ（別の Task の進み具合を待つため）。満たされないまま上限に達したらテストを失敗にする。
func waitUntil(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    // 別スレッドで進む処理（URLSession など）も待てるよう、少しずつ眠りながら最大5秒待つ。
    for _ in 0..<5_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("条件が満たされないまま待ち時間の上限に達した", sourceLocation: sourceLocation)
}
