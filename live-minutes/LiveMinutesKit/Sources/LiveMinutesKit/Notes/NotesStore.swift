import Foundation
import Observation

/// 画面に出すノートと、ライブ更新の状態を持つ（DESIGN.md §4.4）。
///
/// ノートの正は `NotesEngine` が持ち、適用した結果をここへ渡す（`receive(_:)`）。
@MainActor
@Observable
public final class NotesStore {
    public private(set) var notes = Notes()
    /// 直近の適用で追加・変更されたトピックと項目のID。数秒後に消える
    public private(set) var recentlyChangedIDs: Set<String> = []
    public internal(set) var status: LiveNotesStatus = .inactive
    /// 「要約の送信を一時停止」。変更は `SessionController.setNotesSendingPaused(_:)` で行う
    public internal(set) var isSendingPaused = false
    /// 失敗が続いたため、ノートに反映せずに捨てた発言があった
    public private(set) var hasDroppedSegments = false

    @ObservationIgnored private let highlightDuration: Duration
    @ObservationIgnored private var highlightGeneration = 0

    /// - Parameter highlightDuration: ハイライトを消すまでの時間（テストでは短くする）
    public init(highlightDuration: Duration = .seconds(4)) {
        self.highlightDuration = highlightDuration
    }

    /// `NotesEngine` からの知らせを反映する。
    public func receive(_ event: NotesEngine.Event) {
        switch event {
        case .applied(let result):
            apply(result)
        case .status(let status):
            self.status = status
        case .dropped:
            hasDroppedSegments = true
        }
    }

    func apply(_ result: NotesReducer.Result) {
        notes = result.notes
        guard !result.changedIDs.isEmpty else { return }
        recentlyChangedIDs = result.changedIDs
        highlightGeneration += 1
        let generation = highlightGeneration
        let duration = highlightDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            // 新しい適用があった場合は、そちらのハイライトを残す。
            guard let self, self.highlightGeneration == generation else { return }
            self.recentlyChangedIDs = []
        }
    }

    /// 新しいセッションの開始時。一時停止はオフに戻す。
    func reset() {
        notes = Notes()
        recentlyChangedIDs = []
        highlightGeneration += 1
        status = .inactive
        isSendingPaused = false
        hasDroppedSegments = false
    }
}
