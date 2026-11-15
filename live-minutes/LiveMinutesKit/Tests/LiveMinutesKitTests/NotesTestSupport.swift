import Foundation
import Synchronization
import Testing
@testable import LiveMinutesKit

/// 手で進める時計。`sleep(until:)` は `advance(by:)` で時刻が追いついたときに戻る。
final class ManualNotesClock: NotesClock {
    private struct Sleeper {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval = 1000
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    func now() -> TimeInterval {
        state.withLock { $0.now }
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action: Action = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    if state.now >= deadline { return .resume }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            // continuation は必ず1回だけ再開する。登録前に取り消された場合は印を付けておく。
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index).continuation
                }
                state.cancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { state in
            state.now += seconds
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// 応答を手で返す偽の LLMClient。キャンセルされたら CancellationError で戻る。
actor ControlledLLMClient: LLMClient {
    private(set) var requests: [StructuredOutputRequest] = []
    private var waiters: [Int: CheckedContinuation<Result<Data, any Error>, Never>] = [:]
    private var early: [Int: Result<Data, any Error>] = [:]

    func structuredOutput(_ request: StructuredOutputRequest) async throws -> Data {
        let index = requests.count
        requests.append(request)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, any Error>, Never>) in
                if let result = early.removeValue(forKey: index) {
                    continuation.resume(returning: result)
                } else {
                    waiters[index] = continuation
                }
            }
        } onCancel: {
            Task { await self.respond(index, with: .failure(CancellationError())) }
        }
        return try result.get()
    }

    nonisolated func streamText(_ request: TextStreamRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// index 番目（0始まり）のリクエストに応答する。
    func respond(_ index: Int, with result: Result<Data, any Error>) {
        if let waiter = waiters.removeValue(forKey: index) {
            waiter.resume(returning: result)
        } else if index >= requests.count {
            // まだ届いていないリクエストへの応答は、届いたときに返す。
            early[index] = result
        }
    }

    func respond(_ index: Int, ops: [NotesOp]) {
        respond(index, with: .success(Self.data(ops)))
    }

    func respond(_ index: Int, error: LLMError) {
        respond(index, with: .failure(error))
    }

    static func data(_ ops: [NotesOp]) -> Data {
        (try? JSONEncoder().encode(NotesOpsResponse(ops: ops))) ?? Data()
    }

    /// index 番目のリクエストの入力（JSON の文字列）。
    func inputString(_ index: Int) -> String {
        index < requests.count ? requests[index].input : "{}"
    }

    /// index 番目のリクエストで送った発言の本文。
    func sentTexts(_ index: Int) -> [String] {
        (parseJSON(inputString(index))["new_transcript"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
    }
}

/// notes.json に書いた内容を記録する。
actor NotesRecorder {
    private(set) var saved: [Notes] = []

    func record(_ notes: Notes) {
        saved.append(notes)
    }
}

/// 送信のたびに読むモデルの設定を、テストの途中で変えるための入れ物。
@MainActor
final class ModelSelectionBox {
    var model = "gpt-6-luna"
    var effort: String? = "low"
}

func segment(_ text: String, at start: TimeInterval = 0) -> TranscriptSegment {
    TranscriptSegment(start: start, end: start + 1, text: text)
}

/// 指定した文字数の発言。
func segment(characters: Int, at start: TimeInterval = 0) -> TranscriptSegment {
    segment(String(repeating: "あ", count: characters), at: start)
}

func parseJSON(_ string: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] ?? [:]
}
