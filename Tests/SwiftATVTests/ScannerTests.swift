#if canImport(Network)
    import XCTest

    @testable import SwiftATV

    final class ScannerTests: XCTestCase {
        func testCompanionPairingRequirementUsesRpflMask() {
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["rpfl": "0x36782"],
                    for: .companion
                ),
                .mandatory
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["rpFl": "0x627B6"],
                    for: .companion
                ),
                .disabled
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["flags": "512"],
                    for: .companion
                ),
                .unsupported
            )
        }

        func testMRPPairingRequirementUsesAllowPairing() {
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["AllowPairing": "YES"],
                    for: .mrp
                ),
                .optional
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["allowpairing": "no"],
                    for: .mrp
                ),
                .disabled
            )
        }
    }
#endif
