import Testing
import LiveMinutesKit

@Suite("LiveMinutesInfo")
struct LiveMinutesInfoTests {
    @Test("バージョンは 数字.数字.数字 の形になっている")
    func versionHasThreeNumericComponents() {
        let components = LiveMinutesInfo.version.split(separator: ".", omittingEmptySubsequences: false)

        #expect(components.count == 3)
        #expect(components.allSatisfy { Int($0) != nil })
    }
}
