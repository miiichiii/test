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
            MainView(controller: appDelegate.controller)
        }
        .defaultSize(width: 960, height: 600)

        // 設定画面（Cmd+, とツールバーの設定ボタン）
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                secretStore: appDelegate.secretStore,
                connectionTest: appDelegate.connectionTest,
                loadLocales: { await AppleSpeechEngine.supportedLocaleIdentifiers() },
                onAPIKeyChange: { [controller = appDelegate.controller] in
                    Task { await controller.apiKeyDidChange() }
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

    /// 最終確定（最大10秒）と保存を待つ上限。超えたら保存を諦めて終了する。
    private static let terminationTimeout: Duration = .seconds(12)
    /// 終了を待っている間は true。待機中にもう一度呼ばれても、待つ処理を増やさない
    private var isTerminating = false

    override init() {
        let settings = AppSettings()
        // API キーは起動時には読まず、最初に必要になったときにキーチェーンから読んでメモリに持つ。
        let secretStore = CachingSecretStore(base: KeychainStore())
        let llmClient = OpenAIResponsesClient(
            apiKey: { try await secretStore.readAPIKey() },
            onAuthenticationFailure: { await secretStore.invalidate() }
        )
        let repository = SessionRepository(rootDirectory: SessionRepository.defaultRootDirectory)
        let notesFactory = LiveNotesFactory(
            settings: settings,
            secretStore: secretStore,
            client: llmClient,
            repository: repository
        )
        self.settings = settings
        self.secretStore = secretStore
        self.connectionTest = ConnectionTest(client: llmClient)
        self.controller = SessionController(
            engine: AppleSpeechEngine(),
            source: MicrophoneSource(),
            permission: SystemMicrophonePermission(),
            repository: repository,
            clock: SystemSessionClock(),
            recognitionLocale: { settings.recognitionLocale },
            notesEngineFactory: { meta, store in await notesFactory.makeEngine(for: meta, store: store) }
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
