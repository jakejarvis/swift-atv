import XCTest

@testable import SwiftATV

final class ErrorsTests: XCTestCase {
    func testOperationTimeoutDescriptionIncludesStructuredContext() {
        let error = ATVError.operationTimeout(
            TimeoutContext(
                protocol: .companion,
                operation: "request",
                requestID: "_touchStart",
                duration: 5
            )
        )

        XCTAssertEqual(
            error.errorDescription,
            "Operation timeout: Companion request _touchStart 5.0s"
        )
    }
}
