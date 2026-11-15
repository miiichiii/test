import AVFAudio
import Foundation
import Testing
@testable import LiveMinutesKit

@Suite("認識結果からイベントへの変換")
struct TranscriptEventMapperTests {
    @Test("未確定の結果はそのまま volatile になる")
    func volatileResult() {
        let event = TranscriptEventMapper.event(text: "じゃあ", isFinal: false, start: 0, end: 1, lastEnd: 0)
        #expect(event == .volatile("じゃあ"))
    }

    @Test("確定した結果は時刻つきの区間になる")
    func finalResult() throws {
        let event = TranscriptEventMapper.event(text: "延期しましょう", isFinal: true, start: 12.5, end: 14.0, lastEnd: 10)
        guard case .final(let segment) = try #require(event) else {
            Issue.record("final ではない")
            return
        }
        #expect(segment.text == "延期しましょう")
        #expect(segment.start == 12.5)
        #expect(segment.end == 14.0)
    }

    @Test("空白だけの確定結果は捨てる")
    func emptyFinalIsDropped() {
        #expect(TranscriptEventMapper.event(text: " \n", isFinal: true, start: 0, end: 1, lastEnd: 0) == nil)
    }

    @Test("時刻が有限でなければ直前の終わりに寄せる")
    func nonFiniteTimes() throws {
        let event = TranscriptEventMapper.event(text: "はい", isFinal: true, start: .nan, end: .infinity, lastEnd: 8)
        guard case .final(let segment) = try #require(event) else {
            Issue.record("final ではない")
            return
        }
        #expect(segment.start == 8)
        #expect(segment.end == 8)
    }
}
