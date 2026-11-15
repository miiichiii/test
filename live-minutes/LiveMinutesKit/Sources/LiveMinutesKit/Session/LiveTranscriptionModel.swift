import Foundation
import Observation

/// Phase 1 の画面用モデル。開始・停止と、文字起こしの表示内容を持つ。
///
/// Phase 2 で `SessionController` と `TranscriptStore` に置き換える前提の単純なもの。
/// 状態名は `SessionController`（DESIGN.md §4.10）に合わせている。
@MainActor
@Observable
public final class LiveTranscriptionModel {
    public enum State: Equatable, Sendable {
        case idle
        /// 権限の確認やモデルの準備中。ダウンロード中は進捗（0…1）を持つ
        case preparing(progress: Double?)
        case recording
        /// 最後の未確定分を確定させている
        case finishing
    }

    public enum Problem: Equatable, Sendable {
        case microphoneDenied
        case noInputDevice
        case transcriberUnavailable
        case unsupportedLocale
        case modelDownloadFailed
        case other(String)

        /// 画面に出す説明
        public var message: String {
            switch self {
            case .microphoneDenied:
                "マイクの使用が許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」で LiveMinutes を許可してください。"
            case .noInputDevice:
                "マイクが見つかりません。マイクをつないでから、もう一度開始してください。"
            case .transcriberUnavailable:
                "この Mac では端末内の音声認識を使えません。"
            case .unsupportedLocale:
                "日本語の音声認識に対応していません。"
            case .modelDownloadFailed:
                "音声認識モデルのダウンロードに失敗しました。ネットワークを確認して、もう一度開始してください。"
            case .other(let detail):
                "文字起こしを続けられませんでした（\(detail)）。もう一度開始してください。"
            }
        }

        init(_ error: any Error) {
            switch error {
            case AudioSourceError.noInputDevice:
                self = .noInputDevice
            case TranscriptionError.transcriberUnavailable:
                self = .transcriberUnavailable
            case TranscriptionError.unsupportedLocale:
                self = .unsupportedLocale
            case TranscriptionError.modelDownloadFailed:
                self = .modelDownloadFailed
            default:
                self = .other(error.localizedDescription)
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var problem: Problem?
    public private(set) var transcript = TranscriptBuffer()
    /// 入力レベル（0…1）
    public private(set) var inputLevel: Float = 0

    private let engine: any TranscriptionEngine
    private let source: any AudioSource
    private let permission: any MicrophonePermission
    private var isPrepared = false
    private var eventsTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    public init(engine: any TranscriptionEngine, source: any AudioSource, permission: any MicrophonePermission) {
        self.engine = engine
        self.source = source
        self.permission = permission
    }

    public func start() async {
        guard state == .idle else { return }
        problem = nil
        state = .preparing(progress: nil)
        startLevelMonitoringIfNeeded()

        // 未決定のままエンジンを始めると無音になるので、必ず先に許可を確かめる。
        guard await permission.requestAccessIfNeeded() else {
            problem = .microphoneDenied
            state = .idle
            return
        }

        do {
            if !isPrepared {
                try await engine.prepare { [weak self] value in
                    Task { @MainActor in self?.updatePreparingProgress(value) }
                }
                isPrepared = true
            }
            let events = try await engine.start(source: source)
            transcript = TranscriptBuffer()
            state = .recording
            eventsTask = Task { [weak self] in
                do {
                    for try await event in events {
                        self?.transcript.apply(event)
                    }
                    self?.eventsDidFinish(error: nil)
                } catch {
                    self?.eventsDidFinish(error: error)
                }
            }
        } catch {
            problem = Problem(error)
            state = .idle
        }
    }

    public func stop() async {
        guard state == .recording else { return }
        state = .finishing
        await engine.stop()
        // 最後の確定を取りこぼさないよう、イベントを読み終えてから待機に戻す。
        await eventsTask?.value
        eventsTask = nil
        transcript.clearVolatile()
        // 停止の直前に処理中だった tap の値でメーターが残らないよう、ここで0に戻す。
        inputLevel = 0
        state = .idle
    }

    /// テスト用: イベントの読み取りが終わるまで待つ。
    func waitForEvents() async {
        await eventsTask?.value
    }

    private func eventsDidFinish(error: (any Error)?) {
        if let error {
            problem = Problem(error)
        }
        // 停止操作によらずストリームが終わった場合（認識の失敗など）は待機に戻す。
        if state == .recording {
            transcript.clearVolatile()
            inputLevel = 0
            state = .idle
        }
    }

    private func updatePreparingProgress(_ value: Double) {
        guard case .preparing = state else { return }
        state = .preparing(progress: min(max(value, 0), 1))
    }

    private func startLevelMonitoringIfNeeded() {
        guard levelTask == nil else { return }
        let levels = source.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                self?.inputLevel = level
            }
        }
    }
}
