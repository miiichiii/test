import Foundation
import Observation

/// 設定画面が読む Whisper のモデルの状態と操作（ダウンロード・キャンセル・削除）。DESIGN.md §4.2
@MainActor
@Observable
public final class WhisperModelManager {
    public enum ModelState: Equatable, Sendable {
        case unknown
        case notDownloaded
        /// 進み具合（0…1）
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    public private(set) var states: [String: ModelState] = [:]

    @ObservationIgnored private let store: WhisperModelStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init(store: WhisperModelStore) {
        self.store = store
    }

    public func state(of variant: String) -> ModelState {
        states[variant] ?? .unknown
    }

    /// ダウンロード済みかを読み直す（ダウンロード中のものはそのまま）。
    public func refresh() async {
        for variant in WhisperModelStore.variants.map(\.id) {
            if case .downloading = state(of: variant) { continue }
            states[variant] = await store.isDownloaded(variant) ? .downloaded : .notDownloaded
        }
    }

    public func download(_ variant: String) {
        guard tasks[variant] == nil else { return }
        states[variant] = .downloading(0)
        let store = self.store
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.updateProgress(variant, value) }
        }
        tasks[variant] = Task { [weak self] in
            do {
                try await store.download(variant, progress: progress)
                self?.finish(variant, .downloaded)
            } catch is CancellationError {
                self?.finish(variant, .notDownloaded)
            } catch {
                self?.finish(variant, .failed("ダウンロードに失敗しました。ネットワークを確かめて、もう一度試してください。"))
            }
        }
    }

    public func cancel(_ variant: String) {
        tasks[variant]?.cancel()
    }

    public func delete(_ variant: String) async {
        try? await store.delete(variant)
        states[variant] = .notDownloaded
    }

    private func updateProgress(_ variant: String, _ value: Double) {
        guard case .downloading = state(of: variant) else { return }
        states[variant] = .downloading(min(max(value, 0), 1))
    }

    private func finish(_ variant: String, _ state: ModelState) {
        tasks[variant] = nil
        states[variant] = state
    }
}
