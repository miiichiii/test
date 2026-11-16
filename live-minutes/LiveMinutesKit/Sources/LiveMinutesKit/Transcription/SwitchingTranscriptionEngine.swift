import Foundation

/// 書き起こしの方式（DESIGN.md §4.2）
public enum TranscriptionEngineKind: String, CaseIterable, Sendable {
    /// Apple の音声認識（端末内）
    case apple
    /// Whisper（ローカル）
    case whisperLocal
}

/// 設定の書き起こしの方式に従って、Apple の音声認識か Whisper（ローカル）に任せる `TranscriptionEngine`。
///
/// 方式は開始のたびに読む（次に開始する会議から反映）。`SessionController` は認識言語が変わったときだけ
/// `prepare` を呼ぶので、方式が変わっていたら、ここで新しい方式の `prepare` を済ませてから開始する。
public actor SwitchingTranscriptionEngine: TranscriptionEngine {
    private let kind: @MainActor @Sendable () -> TranscriptionEngineKind
    private let apple: any TranscriptionEngine
    private let whisper: any TranscriptionEngine
    private var locale: Locale?
    private var preparedKinds: Set<TranscriptionEngineKind> = []
    private var active: (any TranscriptionEngine)?

    public init(
        kind: @escaping @MainActor @Sendable () -> TranscriptionEngineKind,
        apple: any TranscriptionEngine,
        whisper: any TranscriptionEngine
    ) {
        self.kind = kind
        self.apple = apple
        self.whisper = whisper
    }

    private func engine(for kind: TranscriptionEngineKind) -> any TranscriptionEngine {
        switch kind {
        case .apple: apple
        case .whisperLocal: whisper
        }
    }

    public func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        self.locale = locale
        preparedKinds = []
        let current = await kind()
        try await engine(for: current).prepare(locale: locale, progress: progress)
        preparedKinds.insert(current)
    }

    public func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let current = await kind()
        let selected = engine(for: current)
        if !preparedKinds.contains(current) {
            guard let locale else { throw TranscriptionError.notPrepared }
            try await selected.prepare(locale: locale) { _ in }
            preparedKinds.insert(current)
        }
        let events = try await selected.start(source: source)
        active = selected
        return events
    }

    public func stop() async {
        await active?.stop()
        active = nil
    }
}
