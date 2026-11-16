import Foundation
import os

/// セッションごとに `NotesEngine` を作る。資格情報が設定されていなければ作らない（文字起こしだけで動く）。
@MainActor
public struct LiveNotesFactory {
    private let settings: AppSettings
    /// 今の接続方法で、ライブ更新を動かせるか（API キーなら保存済みか、ChatGPT ならログイン済みでプランの利用が許可されているか）
    private let isConfigured: @MainActor () async -> Bool
    private let client: any LLMClient
    private let repository: SessionRepository
    private let clock: any NotesClock

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Notes")

    public init(
        settings: AppSettings,
        isConfigured: @escaping @MainActor () async -> Bool,
        client: any LLMClient,
        repository: SessionRepository,
        clock: any NotesClock = SystemNotesClock()
    ) {
        self.settings = settings
        self.isConfigured = isConfigured
        self.client = client
        self.repository = repository
        self.clock = clock
    }

    /// API キーだけで使う場合（保存済みかで判断する）。
    public init(
        settings: AppSettings,
        secretStore: any SecretStore,
        client: any LLMClient,
        repository: SessionRepository,
        clock: any NotesClock = SystemNotesClock()
    ) {
        self.init(
            settings: settings,
            isConfigured: { await secretStore.hasAPIKey() },
            client: client,
            repository: repository,
            clock: clock
        )
    }

    /// 接続方法ごとに「設定済みか」を判断する（DESIGN.md §4.11）。
    /// ChatGPT の場合はキーチェーンを読むので、許可ダイアログが出うる（会議の開始とは別の Task で呼ばれる）
    public static func isConfigured(
        settings: AppSettings,
        secretStore: any SecretStore,
        chatGPT: ChatGPTAuth
    ) async -> Bool {
        let method = settings.authMethod
        switch method {
        case .apiKey:
            return await secretStore.hasAPIKey()
        case .chatGPTPlan:
            return await chatGPT.isReadyForPlanUsage()
        }
    }

    /// - Returns: 資格情報が設定されていない、または同梱のプロンプトを読めない場合は nil
    public func makeEngine(for meta: SessionMeta, store: NotesStore) async -> NotesEngine? {
        guard await isConfigured() else { return nil }
        let prompt: String
        let schema: Data
        do {
            prompt = try LLMResources.liveNotesSystemPrompt()
            schema = try LLMResources.notesOpsSchema()
        } catch {
            Self.logger.error("ライブ更新のプロンプトかスキーマを読めない: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        let settings = self.settings
        let repository = self.repository
        let sessionID = meta.id
        return NotesEngine(
            client: client,
            configuration: NotesEngine.Configuration(
                meetingTitle: meta.title,
                glossary: settings.glossary,
                minCharacters: settings.notesMinCharacters,
                maxInterval: settings.notesMaxInterval,
                minInterval: settings.notesMinInterval
            ),
            clock: clock,
            systemPrompt: prompt,
            schema: schema,
            modelSelection: {
                NotesEngine.ModelSelection(
                    model: settings.effectiveLiveModelID,
                    reasoningEffort: AppSettings.effort(settings.liveReasoningEffort)
                )
            },
            persist: { notes in
                do {
                    try await repository.writeNotes(notes, to: sessionID)
                } catch {
                    notesFactoryLogger.error("notes.json を書けない: \(String(describing: type(of: error)), privacy: .public)")
                }
            },
            report: { [weak store] event in store?.receive(event) }
        )
    }
}

private let notesFactoryLogger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Notes")
