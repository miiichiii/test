import Foundation
import Observation
import os

/// 設定画面の「接続テスト」。ライブ更新と同じ形（ノートの差分のスキーマを使う構造化出力）のリクエストを1回送る。
///
/// API キー、モデルID、スキーマが strict モードで受理されるかを、まとめて確かめられる。
@MainActor
@Observable
public final class ConnectionTest {
    public enum Status: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    public private(set) var status: Status = .idle

    private let client: any LLMClient
    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "LLM")

    static let instructions = "これは接続テストです。ノートへの操作はありません。ops を空の配列にして返してください。"

    public init(client: any LLMClient) {
        self.client = client
    }

    /// - Parameters:
    ///   - model: 試すモデルID（ライブ更新用）
    ///   - reasoningEffort: 推論量。空なら送らない
    public func run(model: String, reasoningEffort: String) async {
        guard status != .running else { return }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            status = .failed("モデルIDを入力してください。")
            return
        }
        status = .running
        do {
            let request = StructuredOutputRequest(
                model: model,
                instructions: Self.instructions,
                input: #"{"new_transcript":[]}"#,
                schemaName: "notes_ops",
                schema: try LLMResources.notesOpsSchema(),
                reasoningEffort: AppSettings.effort(reasoningEffort),
                timeout: .seconds(30)
            )
            let output = try await client.structuredOutput(request)
            // 応答がアプリの型として読めることまで確かめる。
            _ = try NotesOpsResponse.decode(from: output)
            status = .succeeded
        } catch let error as LLMError {
            Self.logger.notice("接続テストに失敗: \(error.logSummary, privacy: .public)")
            status = .failed(error.localizedDescription)
        } catch is DecodingError {
            Self.logger.notice("接続テストの応答がノートの形と合わない")
            status = .failed("応答がノートの形式と合いませんでした。")
        } catch is CancellationError {
            status = .idle
        } catch {
            Self.logger.notice("接続テストに失敗: \(type(of: error), privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    public func reset() {
        guard status != .running else { return }
        status = .idle
    }
}
