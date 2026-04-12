import Testing

@testable import SwiftATV

/// New tests written in Swift Testing, coexisting with the XCTest suite.
/// The rest of the test suite remains on XCTest because it is a direct port
/// from pyatv's Python tests; migration can happen incrementally.
@Suite("Playing.description")
struct PlayingDescriptionTests {

    @Test("Position and total time both set")
    func bothSet() {
        let p = Playing(totalTime: 5678, position: 1234)
        #expect(p.description.contains("1234/5678"))
    }

    @Test("Only position set")
    func onlyPosition() {
        let p = Playing(position: 1234)
        let out = p.description
        #expect(out.contains("1234"))
        #expect(!out.contains("/"))
    }

    @Test("Only total time set")
    func onlyTotalTime() {
        let p = Playing(totalTime: 5678)
        let out = p.description
        #expect(out.contains("5678"))
        #expect(!out.contains("/"))
    }

    @Test("Neither set omits position entirely")
    func neitherSet() {
        let p = Playing()
        #expect(!p.description.contains("Position"))
        #expect(!p.description.contains("Total time"))
    }
}
