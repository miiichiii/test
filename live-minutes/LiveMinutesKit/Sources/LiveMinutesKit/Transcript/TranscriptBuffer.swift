/// 確定セグメントと現在の未確定テキスト。`TranscriptEvent` を適用する純粋な値型。
///
/// Phase 1 では画面用の単純な保持に使う。Phase 2 の `TranscriptStore` はこの型を中に持つ想定。
public struct TranscriptBuffer: Equatable, Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText = ""

    public init() {}

    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .final(let segment):
            segments.append(segment)
            volatileText = ""
        }
    }

    /// 停止後に残った未確定テキストを消す。
    public mutating func clearVolatile() {
        volatileText = ""
    }
}
