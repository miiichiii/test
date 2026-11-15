import Foundation

/// 最初に読めた API キーをプロセス内に持つ `SecretStore`（DESIGN.md §4.8）。
///
/// ライブ更新は8〜20秒ごとにリクエストを送る。毎回キーチェーンを読むと、ad-hoc 署名でビルドし直した後に
/// アクセス許可のダイアログが繰り返し出うるので、読めたキーはメモリに持つ（ディスクには書かない）。
/// - 同時の最初の読み出しは1本にまとめる（ダイアログを2枚出さない）
/// - 失敗はキャッシュしない
/// - 保存したら保存した値を持ち、削除したら捨てる。401 を受けたら `invalidate()` で捨てる
public actor CachingSecretStore: SecretStore {
    private let base: any SecretStore
    private var cached: String?
    private var loading: Task<String, any Error>?
    /// 保存・削除・破棄のたびに増やす。読み出しの途中でこれが変わったら、読んだ値をキャッシュしない
    /// （削除したキーがメモリに戻ったり、古いキーで上書きしたりしないため）
    private var generation = 0

    public init(base: any SecretStore) {
        self.base = base
    }

    public func hasAPIKey() async -> Bool {
        if cached != nil { return true }
        return await base.hasAPIKey()
    }

    public func readAPIKey() async throws -> String {
        if let cached { return cached }
        if let loading { return try await loading.value }
        let task = Task { [base] in try await base.readAPIKey() }
        loading = task
        defer { loading = nil }
        let startGeneration = generation
        let key = try await task.value
        if generation == startGeneration {
            cached = key
        }
        return key
    }

    public func saveAPIKey(_ key: String) async throws {
        generation += 1
        try await base.saveAPIKey(key)
        generation += 1
        cached = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func deleteAPIKey() async throws {
        generation += 1
        cached = nil
        try await base.deleteAPIKey()
    }

    /// 持っているキーを捨てる（認証エラーを受けたとき）。
    public func invalidate() {
        generation += 1
        cached = nil
    }
}
