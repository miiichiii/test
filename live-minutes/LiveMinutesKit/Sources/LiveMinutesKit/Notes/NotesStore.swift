import Foundation
import Observation

/// 画面に出すノートと、直近に変更された項目のID（ハイライト用）を持つ（DESIGN.md §4.4）。
///
/// ハイライトを数秒で消す動作と、ライブ更新からの呼び出しは Phase 4 で入れる。
@MainActor
@Observable
public final class NotesStore {
    public private(set) var notes = Notes()
    /// 直近の適用で追加・変更されたトピックと項目のID
    public private(set) var recentlyChangedIDs: Set<String> = []

    public init() {}

    /// 差分操作を適用し、適用しなかった操作の一覧を返す。
    @discardableResult
    public func apply(_ ops: [NotesOp]) -> [NotesReducer.IgnoredOp] {
        let result = NotesReducer.apply(ops, to: notes)
        notes = result.notes
        recentlyChangedIDs = result.changedIDs
        return result.ignored
    }

    public func clearHighlights() {
        recentlyChangedIDs = []
    }

    public func reset() {
        notes = Notes()
        recentlyChangedIDs = []
    }
}
