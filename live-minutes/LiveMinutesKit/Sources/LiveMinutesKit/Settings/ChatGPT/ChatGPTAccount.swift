import Foundation
import Observation

/// 設定画面が読む ChatGPT のログインの状態と操作（DESIGN.md §5・§4.11）。
@MainActor
@Observable
public final class ChatGPTAccount {
    public struct Message: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    public private(set) var state: ChatGPTAuth.State = .unknown
    public private(set) var message: Message?
    /// ログアウトの処理中（ボタンを連打して2本走らせない）
    public private(set) var isSigningOut = false

    @ObservationIgnored private let auth: ChatGPTAuth
    @ObservationIgnored private let openURL: @MainActor (URL) -> Bool
    @ObservationIgnored private let onCredentialsChange: @MainActor () -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - openURL: 既定のブラウザで URL を開く（App 側で `NSWorkspace` を使う）
    ///   - onCredentialsChange: ログイン・ログアウトしたとき（会議中のライブ更新に知らせる）
    public init(
        auth: ChatGPTAuth,
        openURL: @escaping @MainActor (URL) -> Bool,
        onCredentialsChange: @escaping @MainActor () -> Void
    ) {
        self.auth = auth
        self.openURL = openURL
        self.onCredentialsChange = onCredentialsChange
        let updates = auth.stateUpdates
        observation = Task { [weak self] in
            for await newState in updates {
                guard let self else { return }
                let previous = self.state
                self.state = newState
                // 更新の失敗でログインし直しが必要になったときも、ライブ更新に知らせる。
                if case .needsSignIn = newState, previous != newState {
                    self.onCredentialsChange()
                }
            }
        }
        // 起動時にはキーチェーンを読まない（API キーで使う人にも許可ダイアログが出ないように）。
        // 設定画面で ChatGPT プランを選んだときに `load()` で読む。
    }

    /// 保存済みのログインの記録を読む（設定画面で ChatGPT プランを表示したとき）。
    public func load() async {
        await auth.loadState()
    }

    isolated deinit {
        observation?.cancel()
    }

    /// ログインする。成功したら true
    /// - Parameter mode: 同じアカウント・別のアカウント・プランの利用の許可し直し
    @discardableResult
    public func signIn(mode: ChatGPTAuth.SignInMode = .sameAccount) async -> Bool {
        message = nil
        let openURL = self.openURL
        do {
            let result = try await auth.signIn(mode: mode) { url in
                await MainActor.run { openURL(url) }
            }
            if case .signedIn(_, false) = result {
                message = Message(text: LLMError.chatGPTPlanNotGranted.localizedDescription, isError: true)
            } else {
                message = Message(text: "ログインしました", isError: false)
            }
            onCredentialsChange()
            return true
        } catch is CancellationError {
            return false
        } catch {
            message = Message(text: error.localizedDescription, isError: true)
            return false
        }
    }

    public func cancelSignIn() {
        Task { await auth.cancelSignIn() }
    }

    public func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        message = nil
        let result = await auth.signOut()
        message = result.revocationConfirmed
            ? Message(text: "ログアウトしました", isError: false)
            : Message(
                text: "ログアウトしましたが、OpenAI 側での取り消しを確かめられませんでした。ChatGPT の設定からこのアプリを切断できます。",
                isError: true
            )
        onCredentialsChange()
    }

    public func clearMessage() {
        message = nil
    }
}
