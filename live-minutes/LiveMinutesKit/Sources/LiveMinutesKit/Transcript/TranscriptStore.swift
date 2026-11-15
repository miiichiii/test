import Foundation
import Observation

/// 画面に出す文字起こし（DESIGN.md §4.3）。確定セグメントの配列と、現在の未確定テキストを持つ。
///
/// 時刻は録音経過時間（一時停止中を除く）に直したものを入れる。
/// 未確定テキストは頻繁に変わるので、確定セグメントとは別のプロパティにして、
/// 未確定の更新で確定セグメントの一覧を読む View まで再描画させない。
@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText = ""

    public init() {}

    /// 未確定は置き換え、確定は追加して未確定を消す。
    public func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .final(let segment):
            segments.append(segment)
            volatileText = ""
        }
    }

    /// 停止後に残った未確定テキストを消す。
    public func clearVolatile() {
        volatileText = ""
    }

    public func reset() {
        segments = []
        volatileText = ""
    }
}
