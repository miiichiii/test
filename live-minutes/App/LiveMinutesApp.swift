import AppKit
import LiveMinutesKit
import SwiftUI

@main
struct LiveMinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 会議は同時に1つだけ扱うので、複数開ける WindowGroup ではなく単一の Window にする。
        // 単一の Window は閉じるとアプリが終了し、そのときも AppDelegate の終了処理を通る。
        Window("LiveMinutes", id: "main") {
            MainView(controller: appDelegate.controller, settings: appDelegate.settings)
        }
        .defaultSize(width: 960, height: 600)

        // 設定画面（Cmd+, とツールバーの設定ボタン）
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                secretStore: appDelegate.secretStore,
                connectionTest: appDelegate.connectionTest,
                chatGPTAccount: appDelegate.chatGPTAccount,
                loadLocales: { await AppleSpeechEngine.supportedLocaleIdentifiers() },
                onCredentialsChange: { [controller = appDelegate.controller] in
                    Task { await controller.credentialsDidChange() }
                }
            )
        }
    }
}

/// 依存を組み立て、アプリの終了を見張る。録音中・一時停止中に終了するときは、最終確定と保存を終えてから終了する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let secretStore: any SecretStore
    let controller: SessionController
    let connectionTest: ConnectionTest
    let chatGPTAccount: ChatGPTAccount

    /// 最終確定（最大10秒）と保存を待つ上限。超えたら保存を諦めて終了する。
    private static let terminationTimeout: Duration = .seconds(12)
    /// 終了を待っている間は true。待機中にもう一度呼ばれても、待つ処理を増やさない
    private var isTerminating = false

    override init() {
        let settings = AppSettings()
        // API キーは起動時には読まず、最初に必要になったときにキーチェーンから読んでメモリに持つ。
        let secretStore = CachingSecretStore(base: KeychainStore())
        // ChatGPT のログインの情報も、起動時には読まず、最初に必要になったときにキーチェーンから読む（DESIGN.md §4.11）。
        let chatGPTAuth = ChatGPTAuth()
        let credentials = CredentialRouter(
            method: { settings.authMethod },
            apiKey: APIKeyCredentialProvider(
                read: { try await secretStore.readAPIKey() },
                invalidate: { await secretStore.invalidate() }
            ),
            chatGPT: chatGPTAuth
        )
        let llmClient = OpenAIResponsesClient(credentials: credentials)
        let repository = SessionRepository(rootDirectory: SessionRepository.defaultRootDirectory)
        let notesFactory = LiveNotesFactory(
            settings: settings,
            isConfigured: {
                await LiveNotesFactory.isConfigured(settings: settings, secretStore: secretStore, chatGPT: chatGPTAuth)
            },
            client: llmClient,
            repository: repository
        )
        self.settings = settings
        self.secretStore = secretStore
        self.connectionTest = ConnectionTest(client: llmClient, modelCatalog: { try await llmClient.chatGPTModelSlugs() })
        let controller = SessionController(
            engine: AppleSpeechEngine(),
            source: MicrophoneSource(),
            permission: SystemMicrophonePermission(),
            repository: repository,
            clock: SystemSessionClock(),
            recognitionLocale: { settings.recognitionLocale },
            notesEngineFactory: { meta, store in await notesFactory.makeEngine(for: meta, store: store) }
        )
        self.controller = controller
        self.chatGPTAccount = ChatGPTAccount(
            auth: chatGPTAuth,
            openURL: { NSWorkspace.shared.open($0) },
            onCredentialsChange: { Task { await controller.credentialsDidChange() } }
        )
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard controller.needsFinishingBeforeTermination else { return .terminateNow }
        isTerminating = true

        // 保存の完了と上限のどちらか早い方で、1回だけ返事をする。
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await self.controller.finishForTermination()
            reply()
        }
        Task {
            try? await Task.sleep(for: Self.terminationTimeout)
            reply()
        }
        return .terminateLater
    }
}
