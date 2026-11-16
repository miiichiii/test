import Foundation
import Observation

/// アプリの設定（DESIGN.md §4.8）。`UserDefaults` に保存する。API キーはここに持たない（`SecretStore`）。
///
/// モデルIDはコードに埋め込まず設定値として持つ（モデルの世代交代でIDが変わっても、アプリを作り直さずに済むように）。
@MainActor
@Observable
public final class AppSettings {
    // 既定値。モデルIDは 2026-11-15 に OpenAI の公式のモデル一覧で確認した（DESIGN.md §8 #3）。
    public nonisolated static let defaultLiveModelID = "gpt-6-luna"
    public nonisolated static let defaultFinalModelID = "gpt-6.1-sol"
    public nonisolated static let defaultLiveReasoningEffort = "low"
    public nonisolated static let defaultFinalReasoningEffort = "medium"
    public nonisolated static let defaultRecognitionLocaleIdentifier = "ja-JP"
    public nonisolated static let defaultNotesMinCharacters = 120
    public nonisolated static let defaultNotesMaxInterval: TimeInterval = 20
    public nonisolated static let defaultNotesMinInterval: TimeInterval = 8

    enum Key {
        static let liveModelID = "LiveMinutes.liveModelID"
        static let finalModelID = "LiveMinutes.finalModelID"
        static let liveReasoningEffort = "LiveMinutes.liveReasoningEffort"
        static let finalReasoningEffort = "LiveMinutes.finalReasoningEffort"
        static let recognitionLocale = "LiveMinutes.recognitionLocale"
        static let notesMinCharacters = "LiveMinutes.notesMinCharacters"
        static let notesMaxInterval = "LiveMinutes.notesMaxInterval"
        static let notesMinInterval = "LiveMinutes.notesMinInterval"
        static let glossary = "LiveMinutes.glossary"
        static let authMethod = "LiveMinutes.authMethod"
        static let inputDeviceUID = "LiveMinutes.inputDeviceUID"
        static let inputDeviceName = "LiveMinutes.inputDeviceName"
        static let transcriptionEngine = "LiveMinutes.transcriptionEngine"
        static let whisperModel = "LiveMinutes.whisperModel"
    }

    /// 書き起こしの方式（Apple / Whisper（ローカル））。次に開始する会議から反映する
    public var transcriptionEngine: TranscriptionEngineKind {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Key.transcriptionEngine) }
    }

    /// Whisper のモデル（`WhisperModelStore.variants` の id）
    public var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Key.whisperModel) }
    }

    /// 使うマイクの UID（DESIGN.md §4.1「マイクの選択」）。空なら Mac の設定のマイク
    public var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// 使うマイクの名前（つながっていないときの表示用）
    public var inputDeviceName: String {
        didSet { defaults.set(inputDeviceName, forKey: Key.inputDeviceName) }
    }

    /// OpenAI への接続方法（API キーか ChatGPT のプラン。DESIGN.md §4.11）
    public var authMethod: AuthMethod {
        didSet { defaults.set(authMethod.rawValue, forKey: Key.authMethod) }
    }

    /// ライブ更新用（Luna）のモデルID
    public var liveModelID: String {
        didSet { defaults.set(liveModelID, forKey: Key.liveModelID) }
    }

    /// 議事録仕上げ用（Sol）のモデルID
    public var finalModelID: String {
        didSet { defaults.set(finalModelID, forKey: Key.finalModelID) }
    }

    /// ライブ更新の推論量（`reasoning.effort`）。空なら送らない
    public var liveReasoningEffort: String {
        didSet { defaults.set(liveReasoningEffort, forKey: Key.liveReasoningEffort) }
    }

    /// 議事録仕上げの推論量。空なら送らない
    public var finalReasoningEffort: String {
        didSet { defaults.set(finalReasoningEffort, forKey: Key.finalReasoningEffort) }
    }

    /// 認識言語（BCP 47 の識別子。例: `ja-JP`）
    public var recognitionLocaleIdentifier: String {
        didSet {
            let normalized = Self.normalizedLocaleIdentifier(recognitionLocaleIdentifier)
            if normalized != recognitionLocaleIdentifier {
                recognitionLocaleIdentifier = normalized
                return
            }
            defaults.set(recognitionLocaleIdentifier, forKey: Key.recognitionLocale)
        }
    }

    /// ライブ更新の送信条件: 未送信の確定テキストがこの文字数以上たまったら送る
    public var notesMinCharacters: Int {
        didSet { defaults.set(notesMinCharacters, forKey: Key.notesMinCharacters) }
    }

    /// ライブ更新の送信条件: 前回の完了からこの秒数たったら、未送信があれば送る
    public var notesMaxInterval: TimeInterval {
        didSet { defaults.set(notesMaxInterval, forKey: Key.notesMaxInterval) }
    }

    /// ライブ更新の送信条件: 前回の完了からこの秒数以内は送らない
    public var notesMinInterval: TimeInterval {
        didSet { defaults.set(notesMinInterval, forKey: Key.notesMinInterval) }
    }

    /// 固有名詞や専門用語の正しい表記
    public var glossary: [String] {
        didSet { defaults.set(glossary, forKey: Key.glossary) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: テストでは専用の suite を渡す
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveModelID = defaults.string(forKey: Key.liveModelID) ?? Self.defaultLiveModelID
        finalModelID = defaults.string(forKey: Key.finalModelID) ?? Self.defaultFinalModelID
        liveReasoningEffort = defaults.string(forKey: Key.liveReasoningEffort) ?? Self.defaultLiveReasoningEffort
        finalReasoningEffort = defaults.string(forKey: Key.finalReasoningEffort) ?? Self.defaultFinalReasoningEffort
        recognitionLocaleIdentifier = Self.normalizedLocaleIdentifier(
            defaults.string(forKey: Key.recognitionLocale) ?? Self.defaultRecognitionLocaleIdentifier
        )
        notesMinCharacters = defaults.object(forKey: Key.notesMinCharacters) as? Int ?? Self.defaultNotesMinCharacters
        notesMaxInterval = defaults.object(forKey: Key.notesMaxInterval) as? TimeInterval ?? Self.defaultNotesMaxInterval
        notesMinInterval = defaults.object(forKey: Key.notesMinInterval) as? TimeInterval ?? Self.defaultNotesMinInterval
        glossary = defaults.stringArray(forKey: Key.glossary) ?? []
        authMethod = defaults.string(forKey: Key.authMethod).flatMap(AuthMethod.init(rawValue:)) ?? .apiKey
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID) ?? ""
        inputDeviceName = defaults.string(forKey: Key.inputDeviceName) ?? ""
        transcriptionEngine = defaults.string(forKey: Key.transcriptionEngine).flatMap(TranscriptionEngineKind.init(rawValue:)) ?? .apple
        whisperModel = defaults.string(forKey: Key.whisperModel) ?? WhisperModelStore.defaultVariant
    }

    /// 用語の入力欄の文字列（1行に1つ）を、登録する用語の一覧にする。前後の空白を除き、空行と重複を除く
    public nonisolated static func glossaryTerms(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// リクエストに使うライブ更新用のモデルID（前後の空白を除く）。接続テストと本番で同じ値を使うため、ここからだけ読む
    public var effectiveLiveModelID: String {
        liveModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// リクエストに使う議事録仕上げ用のモデルID（前後の空白を除く）
    public var effectiveFinalModelID: String {
        finalModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var recognitionLocale: Locale {
        Locale(identifier: recognitionLocaleIdentifier)
    }

    /// 推論量。空なら nil（リクエストに `reasoning` を入れない）
    public static func effort(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `ja_JP` と `ja-JP` のような表記の違いをそろえる（BCP 47）。
    public static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }
}
