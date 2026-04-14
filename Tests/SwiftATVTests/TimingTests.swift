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

    func testCompanionConnectionRejectsInvalidConnectTimeout() async {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0, connectTimeout: -1)

        do {
            try await connection.connect()
            XCTFail("Expected connect timeout validation to fail")
        } catch let error {
            guard case .invalidConfig(let message) = error else {
                XCTFail("Expected invalidConfig, got \(error)")
                await connection.close()
                return
            }
            XCTAssertEqual(message, "connectTimeout must be a finite non-negative value")
        }

        await connection.close()
    }

    func testMRPConnectionRejectsInvalidConnectTimeout() async {
        let connection = MRPConnection(host: "127.0.0.1", port: 0, connectTimeout: -1)

        do {
            try await connection.connect()
            XCTFail("Expected connect timeout validation to fail")
        } catch let error {
            guard case .invalidConfig(let message) = error else {
                XCTFail("Expected invalidConfig, got \(error)")
                await connection.close()
                return
            }
            XCTAssertEqual(message, "connectTimeout must be a finite non-negative value")
        }

        await connection.close()
    }
}
