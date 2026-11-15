import Foundation
import os

/// セッションごとに `NotesEngine` を作る。API キーがなければ作らない（文字起こしだけで動く）。
@MainActor
public struct LiveNotesFactory {
    private let settings: AppSettings
    private let secretStore: any SecretStore
    private let client: any LLMClient
    private let repository: SessionRepository
    private let clock: any NotesClock

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Notes")

    public init(
        settings: AppSettings,
        secretStore: any SecretStore,
        client: any LLMClient,
        repository: SessionRepository,
        clock: any NotesClock = SystemNotesClock()
    ) {
        self.settings = settings
        self.secretStore = secretStore
        self.client = client
        self.repository = repository
        self.clock = clock
    }

    /// - Returns: API キーがない、または同梱のプロンプトを読めない場合は nil
    public func makeEngine(for meta: SessionMeta, store: NotesStore) async -> NotesEngine? {
        guard await secretStore.hasAPIKey() else { return nil }
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
