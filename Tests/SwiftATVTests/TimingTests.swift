import XCTest

@testable import SwiftATV

final class TimingTests: XCTestCase {
    func testTimeoutNanosecondsConvertsSeconds() throws {
        let nanoseconds = try timeoutNanoseconds(from: 0.25, parameterName: "timeout")

        XCTAssertEqual(nanoseconds, 250_000_000)
    }

    func testTimeoutNanosecondsRejectsNegativeValues() {
        XCTAssertThrowsError(try timeoutNanoseconds(from: -1, parameterName: "timeout"))
    }

    func testTimeoutNanosecondsRejectsNaN() {
        XCTAssertThrowsError(try timeoutNanoseconds(from: .nan, parameterName: "timeout"))
    }

    func testTimeoutNanosecondsRejectsHugeValues() {
        XCTAssertThrowsError(try timeoutNanoseconds(from: .greatestFiniteMagnitude, parameterName: "timeout"))
    }
}
