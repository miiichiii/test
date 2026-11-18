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
            MainView(controller: appDelegate.controller, settings: appDelegate.settings, history: appDelegate.history)
        }
        .defaultSize(width: 960, height: 600)
        .commands { MeetingCommands(controller: appDelegate.controller) }

        // メニューバーから操作できるようにする（Phase 6）。録音中はアイコンで分かる。
        // ラベルは標準の形（タイトルとアイコン名）で渡す。View に独自の読み上げラベルを付けると、
        // 他のアプリが読み上げ情報を問い合わせたときに SwiftUI の中で呼び出しが循環し、落ちることがあった。
        MenuBarExtra("LiveMinutes", systemImage: MenuBarIcon.systemImage(for: appDelegate.controller.state)) {
            MenuBarContent(controller: appDelegate.controller)
        }

        // 設定画面（Cmd+, とツールバーの設定ボタン）
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                secretStore: appDelegate.secretStore,
                connectionTest: appDelegate.connectionTest,
                chatGPTAccount: appDelegate.chatGPTAccount,
                inputDevices: appDelegate.inputDevices,
                whisperModels: appDelegate.whisperModels,
                onInputDeviceChange: { [microphone = appDelegate.microphone] uid in
                    Task { await microphone.setPreferredDevice(uid: uid) }
                },
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
    /// マイク。選び直しを伝えるために持つ
    let microphone: MicrophoneSource
    let inputDevices = AudioInputDeviceList()
    /// Whisper（ローカル）のモデルのダウンロードと削除
    let whisperModels: WhisperModelManager
    /// 過去のセッションの一覧（Phase 5）
    let history: SessionHistory
    /// ネットワークの状態（つながったらノートの送信を再開する。Phase 6）
    private let networkMonitor = NetworkMonitor()
    private var networkTask: Task<Void, Never>?

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
        // 書き起こしは、設定の方式（Apple / Whisper（ローカル））に従って会議ごとに選ぶ（DESIGN.md §4.2）。
        let whisperStore = WhisperModelStore()
        let transcriptionEngine = SwitchingTranscriptionEngine(
            kind: { settings.transcriptionEngine },
            apple: AppleSpeechEngine(contextualStrings: { await MainActor.run { settings.glossary } }),
            whisper: WhisperLocalEngine(
                modelName: { await MainActor.run { settings.whisperModel } },
                load: { name in try await whisperStore.loadTranscriber(name) }
            )
        )
        self.whisperModels = WhisperModelManager(store: whisperStore)
        let microphone = MicrophoneSource(preferredDeviceUID: settings.inputDeviceUID)
        self.microphone = microphone
        self.settings = settings
        self.secretStore = secretStore
        self.connectionTest = ConnectionTest(client: llmClient, modelCatalog: { try await llmClient.chatGPTModelSlugs() })
        // 議事録（Phase 5）。プロンプトを読めなければ作らない（画面に理由を出す）。
        let minutesWriter: (any MinutesGenerating)? = (try? LLMResources.finalMinutesSystemPrompt()).map { prompt in
            MinutesWriter(
                client: llmClient,
                systemPrompt: prompt,
                modelSelection: {
                    NotesEngine.ModelSelection(
                        model: settings.effectiveFinalModelID,
                        reasoningEffort: AppSettings.effort(settings.finalReasoningEffort)
                    )
                },
                isConfigured: {
                    await LiveNotesFactory.isConfigured(settings: settings, secretStore: secretStore, chatGPT: chatGPTAuth)
                }
            )
        }
        self.history = SessionHistory(repository: repository, minutesGenerator: minutesWriter, glossary: { settings.glossary })
        let controller = SessionController(
            engine: transcriptionEngine,
            // マイクと Mac 内の音声を混ぜる（Phase 7）。取り込みがオフなら、マイクをそのまま使う。
            source: MixedAudioSource(
                microphone: microphone,
                system: SystemAudioSource(),
                isSystemAudioEnabled: { settings.captureSystemAudio }
            ),
            permission: SystemMicrophonePermission(),
            repository: repository,
            clock: SystemSessionClock(),
            recognitionLocale: { settings.recognitionLocale },
            notesEngineFactory: { meta, store in await notesFactory.makeEngine(for: meta, store: store) },
            minutesGenerator: minutesWriter,
            glossary: { settings.glossary },
            sleepPreventer: SystemSleepPreventer()
        )
        self.controller = controller
        self.chatGPTAccount = ChatGPTAccount(
            auth: chatGPTAuth,
            openURL: { NSWorkspace.shared.open($0) },
            onCredentialsChange: { Task { await controller.credentialsDidChange() } }
        )
        super.init()
        let availability = networkMonitor.availability
        networkTask = Task { [controller] in
            for await isAvailable in availability where isAvailable {
                controller.networkDidBecomeAvailable()
            }
        }
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
