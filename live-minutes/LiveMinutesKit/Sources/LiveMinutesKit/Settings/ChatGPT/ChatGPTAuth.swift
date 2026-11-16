import Foundation
import os
import Security

/// ChatGPT でのログインと、プランの利用枠のトークンの管理（DESIGN.md §4.11）。
///
/// - ログイン: PKCE の公開クライアント。`127.0.0.1` のループバックでコールバックを受け、コードを交換し、
///   ID トークンを JWKS で検証する。成功するまでは何も保存しない
/// - トークン: 期限の5分前を過ぎたら、リクエストの前に更新する。更新は1本にまとめ、待つ側のキャンセルや締め切りで
///   打ち切らない（独立した Task で走らせる）。新しいトークンは使う前にキーチェーンへ保存する
/// - ログアウト: 走っている更新を（上限つきで）待ち、トークンを消してから、最新のリフレッシュトークンを取り消す
/// - トークン・コード・検証子はログに出さない。ログに出すのは状態の名前とエラーのコードだけ
public actor ChatGPTAuth: CredentialProvider {
    public static let planUsageScope = "chatgpt.tokens.use.direct"
    static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let resource = "https://api.openai.com/v1"
    static let agentName = "LiveMinutes"
    static let dynamicClientID = "dynamic_agent_client"
    /// 文書の例のポート。使えなければ OS に選ばせる
    public static let preferredPort: UInt16 = 1455
    /// 期限のこの秒数前を過ぎたら更新する
    static let refreshMargin: TimeInterval = 300
    /// `earliest_refresh_at` より前でも、期限がこの秒数以内に迫ったら更新する
    static let refreshFloor: TimeInterval = 30
    /// ログアウトで、走っている更新を待つ上限
    static let signOutWaitLimit: Duration = .seconds(10)
    /// 更新が使えなくなったことを表すコード（Errors and recovery の Refresh errors）
    static let terminalRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]

    /// 認証サーバーの URL（`https://auth.openai.com/.well-known/openid-configuration` で確認）
    public struct Endpoints: Sendable {
        public var issuer: String
        public var authorize: URL
        public var token: URL
        public var revoke: URL
        public var jwks: URL

        public init(issuer: String, authorize: URL, token: URL, revoke: URL, jwks: URL) {
            self.issuer = issuer
            self.authorize = authorize
            self.token = token
            self.revoke = revoke
            self.jwks = jwks
        }

        public static var production: Endpoints {
            func url(_ path: String) -> URL {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "auth.openai.com"
                components.path = path
                return components.url ?? URL(filePath: "/")
            }
            return Endpoints(
                issuer: "https://auth.openai.com",
                authorize: url("/api/accounts/authorize"),
                token: url("/api/accounts/oauth/token"),
                revoke: url("/api/accounts/oauth/revoke"),
                jwks: url("/.well-known/jwks.json")
            )
        }
    }

    /// ログインの状態
    public enum State: Equatable, Sendable {
        /// まだ読み込んでいない
        case unknown
        case signedOut
        case signingIn
        case signedIn(email: String?, planUsageGranted: Bool)
        /// トークンが使えなくなった。ログインし直しが必要
        case needsSignIn(email: String?)
        /// キーチェーンから読めない（アクセスを拒否された、など）
        case unavailable
    }

    public struct SignOutResult: Equatable, Sendable {
        /// サーバー側での取り消しを確かめられたか
        public let revocationConfirmed: Bool
    }

    public nonisolated let stateUpdates: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    public private(set) var state: State = .unknown

    private let session: URLSession
    private let endpoints: Endpoints
    private let store: any ChatGPTCredentialStore
    private let hostID: @Sendable () -> String
    private let randomBytes: RandomBytes
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let preferredPort: UInt16?
    private let callbackTimeout: TimeInterval

    private var record: ChatGPTCredentialRecord?
    private var isLoaded = false
    /// キーチェーンからの最初の読み出し（同時の読み出しを1本にまとめ、許可ダイアログを重ねて出さない）
    private var loadingTask: Task<ChatGPTCredentialRecord?, any Error>?
    /// 更新したトークンをキーチェーンに保存できなかった（次の機会に保存し直す。この間はキーチェーンの方が古い）
    private var needsResave = false
    /// キーチェーンへの保存をつなぐ（保存の順序が入れ替わらないように）
    private var saveChain: Task<Bool, Never>?
    private var refreshTask: Task<ChatGPTCredentialRecord, any Error>?
    private var signInTask: Task<State, any Error>?
    /// ログアウトの処理中は、新しい更新を始めない
    private var isSigningOut = false
    /// ログイン・ログアウト・キャンセルのたびに進める。古い世代の結果は保存しない
    private var generation = 0
    private var jwksKeys: [String: SecKey] = [:]

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "ChatGPTAuth")

    /// ログインの種類
    public enum SignInMode: Sendable {
        /// 保存済みの登録（同じアカウント）でログインし直す。登録がなければ新しく登録する
        case sameAccount
        /// 保存済みの登録を使わず、新しく登録する（別のアカウントに替えるとき）
        case newAccount
        /// プランの利用を許可し直す（同意の画面を出す `prompt=consent` を付ける。Errors and recovery）
        case grantPlanUsage
    }

    /// - Parameters:
    ///   - session: テストでは URLProtocol のスタブを入れたセッションを渡す
    ///   - now: 壁時計。トークンの期限はスリープ中も進むので `Date` で測る
    ///   - preferredPort: 先に試す待ち受けのポート。テストでは nil（OS に選ばせる）
    public init(
        session: URLSession = OpenAIResponsesClient.makeSession(),
        endpoints: Endpoints = .production,
        store: any ChatGPTCredentialStore = KeychainChatGPTCredentialStore(),
        hostID: @escaping @Sendable () -> String = { ChatGPTHostIDStore().hostID() },
        randomBytes: @escaping RandomBytes = systemRandomBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        preferredPort: UInt16? = ChatGPTAuth.preferredPort,
        callbackTimeout: TimeInterval = 300
    ) {
        self.session = session
        self.endpoints = endpoints
        self.store = store
        self.hostID = hostID
        self.randomBytes = randomBytes
        self.now = now
        self.sleep = sleep
        self.preferredPort = preferredPort
        self.callbackTimeout = callbackTimeout
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - 状態

    /// 保存済みの記録を読み、状態を返す。
    @discardableResult
    public func loadState() async -> State {
        do {
            _ = try await currentRecord()
        } catch {
            if state != .signingIn { setState(.unavailable) }
        }
        return state
    }

    /// ログイン済みで、プランの利用が許可されているか（ライブ更新を動かせるか）
    public func isReadyForPlanUsage() async -> Bool {
        guard let record = try? await currentRecord() else { return false }
        return record.hasTokens && record.planUsageGranted
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        stateContinuation.yield(newState)
        Self.logger.info("ログインの状態: \(Self.stateName(newState), privacy: .public)")
    }

    private static func stateName(_ state: State) -> String {
        switch state {
        case .unknown: "unknown"
        case .signedOut: "signedOut"
        case .signingIn: "signingIn"
        case .signedIn(_, let granted): "signedIn(planUsageGranted: \(granted))"
        case .needsSignIn: "needsSignIn"
        case .unavailable: "unavailable"
        }
    }

    private static func state(for record: ChatGPTCredentialRecord?) -> State {
        guard let record else { return .signedOut }
        if record.hasTokens {
            return .signedIn(email: record.email, planUsageGranted: record.planUsageGranted)
        }
        return record.reauthenticationRequired ? .needsSignIn(email: record.email) : .signedOut
    }

    /// 失敗やキャンセルの後に戻す状態
    private var settledState: State {
        isLoaded ? Self.state(for: record) : .unavailable
    }

    /// メモリの記録を返す。まだ読んでいなければキーチェーンから読む（同時の読み出しは1本にまとめる）。
    /// 読めなければ投げる（「未ログイン」と区別する。失敗は覚えず、次の呼び出しで読み直す）
    private func currentRecord() async throws -> ChatGPTCredentialRecord? {
        if isLoaded { return record }
        if let loadingTask { return try await loadingTask.value }
        let task = Task { () throws -> ChatGPTCredentialRecord? in
            defer { self.loadingTask = nil }
            let loaded = try await self.store.load()
            // 読んでいる間に別の処理（ログインなど）が記録を決めていたら、そちらを優先する。
            if !self.isLoaded {
                self.record = loaded
                self.isLoaded = true
                if self.state != .signingIn { self.setState(Self.state(for: loaded)) }
            }
            return self.record
        }
        loadingTask = task
        return try await task.value
    }

    // MARK: - CredentialProvider

    public func credential() async throws -> LLMCredential {
        .chatGPTPlan(accessToken: try await accessToken())
    }

    /// 401 を受けた。今のトークンがすでに別のものなら更新せずに true、そうでなければ更新して、できたら true。
    public func handleUnauthorized(_ used: LLMCredential) async -> Bool {
        guard case .chatGPTPlan(let token) = used else { return false }
        guard (try? await currentRecord()) != nil, let current = record, current.hasTokens else { return false }
        if current.accessToken != token { return true }
        do {
            _ = try await refresh()
            return true
        } catch {
            return false
        }
    }

    /// 使えるアクセストークンを返す。期限が近ければ更新する。
    public func accessToken() async throws -> String {
        guard try await currentRecord()?.hasTokens == true else { throw LLMError.chatGPTSignInRequired }
        if needsResave {
            await persistCurrent()
        }
        // await の後は、その時点の記録を読み直す（間に更新が終わっていることがある）。
        guard let current = record, current.hasTokens else { throw LLMError.chatGPTSignInRequired }
        guard current.planUsageGranted else { throw LLMError.chatGPTPlanNotGranted }
        let latest = shouldRefresh(current) ? try await refresh() : current
        guard let token = latest.accessToken else { throw LLMError.chatGPTSignInRequired }
        return token
    }

    // MARK: - 更新

    private func shouldRefresh(_ record: ChatGPTCredentialRecord) -> Bool {
        guard let expiresAt = record.accessTokenExpiresAt else { return true }
        let current = now()
        guard current >= expiresAt.addingTimeInterval(-Self.refreshMargin) else { return false }
        if let earliest = record.earliestRefreshAt, current < earliest,
           current < expiresAt.addingTimeInterval(-Self.refreshFloor) {
            return false
        }
        return true
    }

    /// 今の記録で更新する。走っている更新があればそれを待つ（1本にまとめる）。
    private func refresh() async throws -> ChatGPTCredentialRecord {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard !isSigningOut, let current = record, current.hasTokens else { throw LLMError.chatGPTSignInRequired }
        let startGeneration = generation
        // 独立した Task で走らせ、待つ側のキャンセルや締め切りで打ち切らない（打ち切ると、サーバー側では置き換えが
        // 済んでいるのに新しいリフレッシュトークンを受け取れず、ログインし直しになるため）。
        let task = Task { try await self.performRefresh(from: current, generation: startGeneration) }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh(from used: ChatGPTCredentialRecord, generation startGeneration: Int) async throws -> ChatGPTCredentialRecord {
        defer { refreshTask = nil }
        // 別のプロセス（デバッグ版とビルド済みの版など）がすでに更新していれば、それを使う。
        if let adopted = await adoptableFromStore(insteadOf: used) {
            record = adopted
            if !shouldRefresh(adopted) { return adopted }
            return try await sendRefresh(adopted, generation: startGeneration, mayAdopt: false)
        }
        return try await sendRefresh(used, generation: startGeneration, mayAdopt: true)
    }

    /// キーチェーンの記録が、同じ登録のより新しいトークンを持っていれば返す。
    ///
    /// 保存に失敗している間（`needsResave`）はキーチェーンの方が古いので使わない。期限がメモリより新しいものだけを
    /// 「別のプロセスの更新」とみなす（古い記録で使用済みのトークンを送らないように）。
    private func adoptableFromStore(insteadOf used: ChatGPTCredentialRecord) async -> ChatGPTCredentialRecord? {
        guard !needsResave, let stored = (try? await store.load()) ?? nil, !needsResave else { return nil }
        guard stored.hasTokens, stored.clientID == used.clientID, stored.subject == used.subject,
              stored.refreshToken != used.refreshToken,
              let storedExpiry = stored.accessTokenExpiresAt,
              storedExpiry > (used.accessTokenExpiresAt ?? .distantPast)
        else { return nil }
        return stored
    }

    private func sendRefresh(_ current: ChatGPTCredentialRecord, generation startGeneration: Int, mayAdopt: Bool) async throws -> ChatGPTCredentialRecord {
        guard let refreshToken = current.refreshToken else { throw LLMError.chatGPTSignInRequired }
        let body = OAuthEncoding.formBody([
            ("grant_type", "refresh_token"),
            ("client_id", current.clientID),
            ("refresh_token", refreshToken),
            ("resource", Self.resource),
        ])
        let (status, data) = try await postForm(endpoints.token, body: body)
        if status == 200 {
            guard let tokens = try? Self.decodeTokens(data), let accessToken = tokens.accessToken else {
                throw LLMError.invalidOutput
            }
            var updated = current
            updated.accessToken = accessToken
            updated.refreshToken = tokens.refreshToken ?? refreshToken
            updated.idToken = tokens.idToken ?? current.idToken
            updated.accessTokenExpiresAt = now().addingTimeInterval(tokens.expiresIn ?? 3600)
            updated.earliestRefreshAt = tokens.earliestRefreshAt
            if let scope = tokens.scope { updated.scopes = Self.scopes(from: scope) }
            updated.reauthenticationRequired = false
            // ログアウトやログインが挟まっていたら、古い世代の結果は使わない。受け取った新しいリフレッシュトークンは、
            // サーバー側に残らないよう取り消す。
            guard generation == startGeneration else {
                if let newRefreshToken = tokens.refreshToken {
                    _ = await revoke(refreshToken: newRefreshToken, clientID: current.clientID)
                }
                throw LLMError.chatGPTSignInRequired
            }
            record = updated
            await persistCurrent()
            setState(Self.state(for: updated))
            Self.logger.info("トークンを更新した")
            return updated
        }

        let code = Self.oauthErrorCode(data)
        Self.logger.notice("トークンの更新に失敗: status \(status), code \(code ?? "-", privacy: .public)")
        if let code, Self.terminalRefreshCodes.contains(code) {
            // 別のプロセスが先に更新していた場合は、消さずにそちらで1回だけやり直す。
            if mayAdopt, let adopted = await adoptableFromStore(insteadOf: current) {
                record = adopted
                if !shouldRefresh(adopted) { return adopted }
                return try await sendRefresh(adopted, generation: startGeneration, mayAdopt: false)
            }
            guard generation == startGeneration, let latest = record else { throw LLMError.chatGPTSignInRequired }
            // ID トークンは残す（ログインし直すときの id_token_hint に使う）。
            var cleared = latest.withoutTokens(keepingIDToken: true)
            cleared.reauthenticationRequired = true
            record = cleared
            await persistCurrent()
            setState(Self.state(for: cleared))
            throw LLMError.chatGPTSignInRequired
        }
        if code == "invalid_client" {
            throw LLMError.chatGPTRejected(code: code)
        }
        if status == 429 {
            throw LLMError.rateLimited
        }
        if (500...599).contains(status) {
            throw LLMError.server(status: status)
        }
        // そのほかの失敗では、トークンを捨てない（一時的な障害でログインし直しにしないため）。
        throw LLMError.chatGPTRejected(code: code)
    }

    // MARK: - 保存

    /// その時点のメモリの記録をキーチェーンに保存する。失敗したらメモリの記録で続け、次の機会に保存し直す。
    @discardableResult
    private func persistCurrent() async -> Bool {
        await enqueueSave(nil)
    }

    /// 決まった記録を保存する（ログインの結果。失敗してもメモリの記録には触れない）。
    private func persist(_ fixed: ChatGPTCredentialRecord) async -> Bool {
        await enqueueSave(fixed)
    }

    /// 保存を前の保存の後につなぐ（2つの保存の到着順が入れ替わって、古い記録で上書きしないように）。
    private func enqueueSave(_ fixed: ChatGPTCredentialRecord?) async -> Bool {
        let previous = saveChain
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await self.write(fixed)
        }
        saveChain = task
        return await task.value
    }

    private func write(_ fixed: ChatGPTCredentialRecord?) async -> Bool {
        guard let target = fixed ?? record else { return true }
        do {
            try await store.save(target)
            if fixed == nil || target == record { needsResave = false }
            return true
        } catch {
            if fixed == nil { needsResave = true }
            Self.logger.error("ログインの記録をキーチェーンに保存できない: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    // MARK: - ログイン

    /// ログインする。ブラウザでの許可を待ち、終わったら状態を返す。
    /// - Parameters:
    ///   - mode: 同じアカウントでのログインし直し、別のアカウントでの新しい登録、プランの利用の許可し直し
    ///   - openURL: 既定のブラウザで URL を開く。開けなければ false
    public func signIn(
        mode: SignInMode = .sameAccount,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws -> State {
        // 前のログインを止め、待ち受け（1455）を閉じ終えてから始める。
        if let previous = signInTask {
            previous.cancel()
            _ = try? await previous.value
        }
        generation += 1
        let attemptGeneration = generation
        let task = Task { try await self.performSignIn(mode: mode, generation: attemptGeneration, openURL: openURL) }
        signInTask = task
        setState(.signingIn)
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if generation == attemptGeneration { signInTask = nil }
            return result
        } catch {
            if generation == attemptGeneration {
                signInTask = nil
                setState(settledState)
            }
            Self.logger.notice("ログインに失敗: \(Self.errorName(error), privacy: .public)")
            throw error
        }
    }

    /// 進めているログインをやめる。
    public func cancelSignIn() {
        guard let signInTask else { return }
        signInTask.cancel()
        self.signInTask = nil
        generation += 1
        setState(settledState)
    }

    private func performSignIn(
        mode: SignInMode,
        generation attemptGeneration: Int,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws -> State {
        // 読めない場合は、新しい登録としてログインする（利用者がログインを選んだので、上書きしてよい）。
        let existing = (try? await currentRecord()) ?? nil
        let reused = mode == .newAccount ? nil : existing
        let savedClientID = reused?.clientID
        let verifier = OAuthEncoding.base64URL(randomBytes(32))
        let expectedState = OAuthEncoding.base64URL(randomBytes(32))
        let nonce = OAuthEncoding.base64URL(randomBytes(32))

        let server: LoopbackCallbackServer
        do {
            server = try await LoopbackCallbackServer.start(preferredPort: preferredPort, timeout: callbackTimeout) { parameters in
                parameters["state"] == expectedState ? .accept : .reject
            }
        } catch {
            throw ChatGPTSignInError.cannotListen
        }
        // コールバックを受け取った場合だけ、完了のページを返し終えるまで少し待ってから閉じる。
        // それ以外（失敗・キャンセル）はすぐ閉じ、1455 をつかんだままにしない。
        var receivedCallback = false
        defer { server.stop(after: receivedCallback ? 3 : 0) }

        let redirectURI = server.redirectURI
        guard let url = authorizeURL(
            clientID: savedClientID,
            idTokenHint: savedClientID == nil ? nil : reused?.idToken,
            promptConsent: mode == .grantPlanUsage,
            redirectURI: redirectURI,
            state: expectedState,
            nonce: nonce,
            verifier: verifier
        ) else {
            throw ChatGPTSignInError.cannotListen
        }
        guard await openURL(url) else { throw ChatGPTSignInError.cannotOpenBrowser }

        let parameters: [String: String]
        do {
            parameters = try await server.waitForCallback()
        } catch LoopbackCallbackServer.ServerError.timedOut {
            throw ChatGPTSignInError.timedOut
        } catch is LoopbackCallbackServer.ServerError {
            throw ChatGPTSignInError.cannotListen
        }
        receivedCallback = true
        if let error = parameters["error"] {
            throw error == "access_denied"
                ? ChatGPTSignInError.accessDenied
                : ChatGPTSignInError.authorizationFailed(code: Self.sanitizedCode(error))
        }
        guard let code = parameters["code"], !code.isEmpty else { throw ChatGPTSignInError.invalidCallback }

        let clientID: String
        if let savedClientID {
            if let returned = parameters["client_id"], !returned.isEmpty, returned != savedClientID {
                throw ChatGPTSignInError.clientMismatch
            }
            clientID = savedClientID
        } else {
            guard let returned = parameters["client_id"], !returned.isEmpty, returned != Self.dynamicClientID else {
                throw ChatGPTSignInError.registrationIncomplete
            }
            clientID = returned
        }

        let tokens = try await exchange(code: code, clientID: clientID, verifier: verifier, redirectURI: redirectURI)
        guard let idToken = tokens.idToken, let accessToken = tokens.accessToken, let refreshToken = tokens.refreshToken else {
            throw ChatGPTSignInError.invalidTokenResponse
        }
        let claims: IDTokenClaims
        do {
            claims = try await verifyIDToken(idToken, clientID: clientID, nonce: nonce)
        } catch let error as IDTokenError {
            throw ChatGPTSignInError.invalidIDToken(error)
        }
        // 保存済みの登録で、別のアカウントが返ってきたら置き換えない（文書の指示）。
        if savedClientID != nil, let reused, reused.subject != claims.subject {
            throw ChatGPTSignInError.accountMismatch
        }
        try Task.checkCancellation()
        guard generation == attemptGeneration else { throw CancellationError() }

        let newRecord = ChatGPTCredentialRecord(
            clientID: clientID,
            subject: claims.subject,
            email: claims.email,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: now().addingTimeInterval(tokens.expiresIn ?? 3600),
            earliestRefreshAt: tokens.earliestRefreshAt,
            // 応答に scope がなければ、プランの利用は許可されていないものとして扱う（文書に記載がないので安全な側）。
            scopes: tokens.scope.map(Self.scopes(from:)) ?? [],
            reauthenticationRequired: false
        )
        guard await persist(newRecord) else { throw ChatGPTSignInError.cannotSave }
        record = newRecord
        isLoaded = true
        needsResave = false
        let newState = Self.state(for: newRecord)
        setState(newState)
        Self.logger.info("ログインした")
        return newState
    }

    /// 認可の URL。値はすべて自前でエンコードする（`+` などを含んでも壊れないように）。
    func authorizeURL(
        clientID: String?,
        idTokenHint: String?,
        promptConsent: Bool = false,
        redirectURI: String,
        state: String,
        nonce: String,
        verifier: String
    ) -> URL? {
        var pairs: [(String, String)] = [("client_id", clientID ?? Self.dynamicClientID)]
        if clientID == nil {
            pairs.append(("agent_name_hint", Self.agentName))
        }
        pairs.append(("ext_agent_host_id", hostID()))
        if clientID != nil, let idTokenHint {
            pairs.append(("id_token_hint", idTokenHint))
        }
        pairs += [
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", Self.requestedScopes),
            ("resource", Self.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", OAuthEncoding.codeChallenge(for: verifier)),
        ]
        if promptConsent {
            pairs.append(("prompt", "consent"))
        }
        return URL(string: "\(endpoints.authorize.absoluteString)?\(OAuthEncoding.formBody(pairs))")
    }

    /// コールバックの `error` を、ログと画面に出せる形にする（英数字と `_` だけ、64文字まで）。
    static func sanitizedCode(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        let text = String(String.UnicodeScalarView(filtered.prefix(64)))
        return text.isEmpty ? "unknown" : text
    }

    private func exchange(code: String, clientID: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        let body = OAuthEncoding.formBody([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", Self.resource),
        ])
        let status: Int
        let data: Data
        do {
            (status, data) = try await postForm(endpoints.token, body: body)
        } catch let error as LLMError {
            throw ChatGPTSignInError.network(error)
        }
        guard status == 200 else {
            let code = Self.oauthErrorCode(data)
            throw code == "invalid_grant" ? ChatGPTSignInError.invalidGrant : ChatGPTSignInError.tokenExchangeFailed(code: code)
        }
        guard let tokens = try? Self.decodeTokens(data) else { throw ChatGPTSignInError.invalidTokenResponse }
        return tokens
    }

    private func verifyIDToken(_ token: String, clientID: String, nonce: String) async throws -> IDTokenClaims {
        let parts = try IDTokenVerifier.split(token)
        guard parts.header.alg == "RS256" else { throw IDTokenError.unsupportedAlgorithm }
        guard let kid = parts.header.kid else { throw IDTokenError.unknownKey }
        if jwksKeys[kid] == nil {
            // 知らない鍵なら1回だけ取り直す（鍵の入れ替えに備える）。
            try await loadJWKS()
        }
        guard let key = jwksKeys[kid] else { throw IDTokenError.unknownKey }
        try IDTokenVerifier.verifySignature(parts, key: key)
        return try IDTokenVerifier.verifyClaims(parts.payload, issuer: endpoints.issuer, clientID: clientID, nonce: nonce, now: now())
    }

    private func loadJWKS() async throws {
        var request = URLRequest(url: endpoints.jwks, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ChatGPTSignInError.network(.network)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IDTokenError.unknownKey }
        jwksKeys = try IDTokenVerifier.publicKeys(from: data)
    }

    // MARK: - ログアウト

    /// ログアウトする。走っている更新を（上限つきで）待ち、トークンを消してから、最新のリフレッシュトークンを取り消す。
    /// `client_id`、`sub`、ホストIDは残す（次のログインのため）。
    public func signOut() async -> SignOutResult {
        isSigningOut = true
        defer { isSigningOut = false }
        if let signInTask {
            signInTask.cancel()
            self.signInTask = nil
        }
        if let refreshTask {
            await waitBounded(refreshTask)
        }
        generation += 1
        let current: ChatGPTCredentialRecord?
        do {
            current = try await currentRecord()
        } catch {
            // 読めなければ、取り消しも消去もできない。
            setState(.unavailable)
            return SignOutResult(revocationConfirmed: false)
        }
        guard let current else {
            setState(.signedOut)
            return SignOutResult(revocationConfirmed: true)
        }
        let refreshToken = current.refreshToken
        // 取り消し（時間がかかりうる）の前に、手元のトークンを消す（その間にアプリを終了してもトークンを残さない）。
        var cleared = current.withoutTokens()
        cleared.reauthenticationRequired = false
        record = cleared
        isLoaded = true
        if !(await persistCurrent()) {
            // 書き換えられなければ、トークンを残さないよう項目ごと消す。
            try? await store.delete()
            record = nil
            needsResave = false
        }
        setState(.signedOut)
        var confirmed = true
        if let refreshToken {
            confirmed = await revoke(refreshToken: refreshToken, clientID: current.clientID)
        }
        Self.logger.info("ログアウトした（取り消しの確認: \(confirmed)）")
        return SignOutResult(revocationConfirmed: confirmed)
    }

    /// 更新の完了か上限の早い方まで待つ。`withTaskGroup` は子を全部待つので使わない。
    private func waitBounded(_ task: Task<ChatGPTCredentialRecord, any Error>) async {
        let sleep = self.sleep
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            _ = try? await task.value
            continuation.yield()
        }
        let timer = Task {
            try? await sleep(Self.signOutWaitLimit)
            continuation.yield()
        }
        for await _ in stream { break }
        continuation.finish()
        waiter.cancel()
        timer.cancel()
    }

    /// リフレッシュトークンを取り消す。通信エラーや 5xx は、間隔を空けて最大2回まで送り直す。
    private func revoke(refreshToken: String, clientID: String) async -> Bool {
        let body = OAuthEncoding.formBody([
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", clientID),
        ])
        for attempt in 0..<3 {
            if attempt > 0 { try? await sleep(.seconds(attempt)) }
            do {
                let (status, _) = try await postForm(endpoints.revoke, body: body)
                if status == 200 { return true }
                if !(500...599).contains(status) { return false }
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: - 通信

    private func postForm(_ url: URL, body: String) async throws -> (Int, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidOutput }
            return (http.statusCode, data)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw OpenAIResponsesClient.map(error)
        }
    }

    struct TokenResponse {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
        let earliestRefreshAt: Date?
    }

    static func decodeTokens(_ data: Data) throws -> TokenResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidOutput
        }
        return TokenResponse(
            accessToken: object["access_token"] as? String,
            refreshToken: object["refresh_token"] as? String,
            idToken: object["id_token"] as? String,
            expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue,
            scope: object["scope"] as? String,
            earliestRefreshAt: flexibleDate(object["earliest_refresh_at"])
        )
    }

    /// `earliest_refresh_at` の形は文書にないので、Unix 秒（数値・数字の文字列）と ISO 8601 の両方を読む。
    static func flexibleDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let text = value as? String {
            if let seconds = TimeInterval(text) { return Date(timeIntervalSince1970: seconds) }
            return try? Date(text, strategy: .iso8601)
        }
        return nil
    }

    /// OAuth のエラー応答からコードを取り出す（`{"error": "invalid_grant"}` と `{"error": {"code": …}}` の両方）。
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any], let code = error["code"] as? String { return code }
        return object["code"] as? String
    }

    static func scopes(from value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
    }

    private static func errorName(_ error: any Error) -> String {
        switch error {
        case let error as ChatGPTSignInError: error.logSummary
        case is CancellationError: "cancelled"
        default: String(describing: type(of: error))
        }
    }
}

/// ログインの失敗。中身（トークンやコード）は持たない。
public enum ChatGPTSignInError: Error, Equatable, Sendable {
    case cannotListen
    case cannotOpenBrowser
    case timedOut
    case accessDenied
    case authorizationFailed(code: String)
    case invalidCallback
    case clientMismatch
    case registrationIncomplete
    case invalidGrant
    case tokenExchangeFailed(code: String?)
    case invalidTokenResponse
    case invalidIDToken(IDTokenError)
    case accountMismatch
    case cannotSave
    case network(LLMError)

    var logSummary: String {
        switch self {
        case .cannotListen: "cannotListen"
        case .cannotOpenBrowser: "cannotOpenBrowser"
        case .timedOut: "timedOut"
        case .accessDenied: "accessDenied"
        case .authorizationFailed(let code): "authorizationFailed(\(code))"
        case .invalidCallback: "invalidCallback"
        case .clientMismatch: "clientMismatch"
        case .registrationIncomplete: "registrationIncomplete"
        case .invalidGrant: "invalidGrant"
        case .tokenExchangeFailed(let code): "tokenExchangeFailed(\(code ?? "-"))"
        case .invalidTokenResponse: "invalidTokenResponse"
        case .invalidIDToken(let error): "invalidIDToken(\(error))"
        case .accountMismatch: "accountMismatch"
        case .cannotSave: "cannotSave"
        case .network(let error): "network(\(error.logSummary))"
        }
    }
}

extension ChatGPTSignInError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotListen:
            "ログインの準備ができませんでした（この Mac での待ち受けを始められません）。"
        case .cannotOpenBrowser:
            "ブラウザを開けませんでした。"
        case .timedOut:
            "時間内にログインが終わりませんでした。もう一度試してください。"
        case .accessDenied:
            "ブラウザで許可されなかったため、ログインしませんでした。"
        case .authorizationFailed(let code):
            "ログインできませんでした（\(code)）。"
        case .invalidCallback:
            "ログインの応答を読み取れませんでした。もう一度試してください。"
        case .clientMismatch:
            "ログインの応答が、このアプリの登録と合いませんでした。"
        case .registrationIncomplete:
            "アプリの登録が完了しませんでした。もう一度試してください。"
        case .invalidGrant:
            "ログインの確認に失敗しました。もう一度試してください。"
        case .tokenExchangeFailed(let code):
            "ログインの確認に失敗しました（\(code ?? "不明なエラー")）。"
        case .invalidTokenResponse:
            "ログインの応答を読み取れませんでした。"
        case .invalidIDToken:
            "ログインの応答を検証できませんでした。"
        case .accountMismatch:
            "前回と別の ChatGPT のアカウントが選ばれたため、ログインしませんでした。別のアカウントを使うときは「別のアカウントでログイン」を押してください。"
        case .cannotSave:
            "ログインの情報をキーチェーンに保存できませんでした。"
        case .network(let error):
            error.localizedDescription
        }
    }
}
