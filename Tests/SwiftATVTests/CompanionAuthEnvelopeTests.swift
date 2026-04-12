import Foundation
import Testing

@testable import SwiftATV

/// Tests for the shared OPACK auth envelope used by Companion pair-setup
/// and pair-verify. Pins two invariants that an earlier pair-verify
/// implementation got wrong:
/// 1. Inner TLV8 bytes must be wrapped in an OPACK dict (`{_pd, _auTy: 4}`).
///    Real Apple TVs reject raw TLV8.
/// 2. `_auTy` appears only on the `PV_Start` frame; pyatv (and we) drop it
///    from `PV_Next`.
///
/// These tests pin the exact wire format so future edits can't regress it.
@Suite("Companion auth OPACK envelope")
struct CompanionAuthEnvelopeTests {

    private let innerTLV = Data([0x06, 0x01, 0x01, 0x03, 0x02, 0xAA, 0xBB])

    @Test("PS_Start envelope contains _pd + _pwTy: 1")
    func pairSetupStartEnvelope() throws {
        let encoded = wrapCompanionAuthEnvelope(
            innerTLV: innerTLV,
            authTypeKey: "_pwTy",
            authTypeValue: 1
        )
        let decoded = try OPACK.decode(encoded)
        guard case .dict(let pairs) = decoded else {
            Issue.record("Expected OPACK dict")
            return
        }
        let keys = pairs.compactMap { $0.0.stringValue }
        #expect(keys.contains("_pd"))
        #expect(keys.contains("_pwTy"))
        #expect(decoded["_pd"]?.dataValue == innerTLV)
        #expect(decoded["_pwTy"]?.intValue == 1)
    }

    @Test("PV_Start envelope contains _pd + _auTy: 4")
    func pairVerifyStartEnvelope() throws {
        let encoded = wrapCompanionAuthEnvelope(
            innerTLV: innerTLV,
            authTypeKey: "_auTy",
            authTypeValue: 4
        )
        let decoded = try OPACK.decode(encoded)
        #expect(decoded["_pd"]?.dataValue == innerTLV)
        #expect(decoded["_auTy"]?.intValue == 4)
    }

    @Test("PV_Next envelope contains only _pd (no _auTy)")
    func pairVerifyNextOmitsAuthType() throws {
        let encoded = wrapCompanionAuthEnvelope(innerTLV: innerTLV)
        let decoded = try OPACK.decode(encoded)
        guard case .dict(let pairs) = decoded else {
            Issue.record("Expected OPACK dict")
            return
        }
        let keys = pairs.compactMap { $0.0.stringValue }
        #expect(keys == ["_pd"])  // exactly one entry
        #expect(decoded["_pd"]?.dataValue == innerTLV)
        #expect(decoded["_auTy"] == nil)
    }

    @Test("unwrap returns inner TLV on a well-formed response")
    func unwrapWellFormed() throws {
        let encoded = wrapCompanionAuthEnvelope(
            innerTLV: innerTLV,
            authTypeKey: "_pwTy",
            authTypeValue: 1
        )
        let inner = try unwrapCompanionAuthEnvelope(encoded)
        #expect(inner == innerTLV)
    }

    @Test("unwrap throws when the response is not a dict with _pd")
    func unwrapRejectsMissingPd() {
        let notADict = OPACK.encode(.string("nope"))
        #expect(throws: ATVError.self) {
            try unwrapCompanionAuthEnvelope(notADict)
        }
    }

    @Test("unwrap throws authenticationFailed when the inner TLV carries an error tag")
    func unwrapSurfacesHapError() throws {
        // Build an inner TLV with state=2 + error=0x02 (Authentication).
        let errorInner = TLV8.encode([
            TLV8.Entry(tag: .state, value: 2),
            TLV8.Entry(tag: .error, value: 0x02),
        ])
        let encoded = wrapCompanionAuthEnvelope(innerTLV: errorInner)

        var thrown: ATVError?
        do {
            _ = try unwrapCompanionAuthEnvelope(encoded)
        } catch {
            thrown = error
        }
        guard case .authenticationFailed = thrown else {
            Issue.record("Expected authenticationFailed, got \(String(describing: thrown))")
            return
        }
    }
}
