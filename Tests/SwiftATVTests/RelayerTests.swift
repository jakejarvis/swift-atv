import XCTest

@testable import SwiftATV

/// Tests for the Relayer priority-based routing system.
final class RelayerTests: XCTestCase {

    // MARK: - Priority ordering

    func testRelayerDefaultPriority() {
        let relayer = Relayer<String>()

        relayer.register("companion-impl", for: .companion)
        relayer.register("mrp-impl", for: .mrp)

        // MRP has higher priority than Companion by default
        XCTAssertEqual(relayer.main, "mrp-impl")
    }

    func testRelayerDMAPHigherThanCompanion() {
        let relayer = Relayer<String>()

        relayer.register("companion-impl", for: .companion)
        relayer.register("dmap-impl", for: .dmap)

        // DMAP has higher priority than Companion
        XCTAssertEqual(relayer.main, "dmap-impl")
    }

    func testRelayerCompanionHigherThanAirPlay() {
        let relayer = Relayer<String>()

        relayer.register("airplay-impl", for: .airPlay)
        relayer.register("companion-impl", for: .companion)

        // Companion has higher priority than AirPlay
        XCTAssertEqual(relayer.main, "companion-impl")
    }

    func testRelayerAirPlayHigherThanRAOP() {
        let relayer = Relayer<String>()

        relayer.register("raop-impl", for: .raop)
        relayer.register("airplay-impl", for: .airPlay)

        XCTAssertEqual(relayer.main, "airplay-impl")
    }

    func testRelayerFullPriorityOrder() {
        let relayer = Relayer<String>()

        relayer.register("raop-impl", for: .raop)
        XCTAssertEqual(relayer.main, "raop-impl")

        relayer.register("airplay-impl", for: .airPlay)
        XCTAssertEqual(relayer.main, "airplay-impl")

        relayer.register("companion-impl", for: .companion)
        XCTAssertEqual(relayer.main, "companion-impl")

        relayer.register("dmap-impl", for: .dmap)
        XCTAssertEqual(relayer.main, "dmap-impl")

        relayer.register("mrp-impl", for: .mrp)
        XCTAssertEqual(relayer.main, "mrp-impl")
    }

    // MARK: - Get specific protocol

    func testRelayerGetSpecificProtocol() {
        let relayer = Relayer<String>()

        relayer.register("mrp-impl", for: .mrp)
        relayer.register("companion-impl", for: .companion)

        XCTAssertEqual(relayer.get(for: .mrp), "mrp-impl")
        XCTAssertEqual(relayer.get(for: .companion), "companion-impl")
        XCTAssertNil(relayer.get(for: .dmap))
    }

    // MARK: - Takeover

    func testRelayerTakeover() {
        let relayer = Relayer<String>()

        relayer.register("mrp-impl", for: .mrp)
        relayer.register("companion-impl", for: .companion)

        XCTAssertEqual(relayer.main, "mrp-impl")

        // Takeover forces companion
        let release = relayer.takeover(.companion)
        XCTAssertEqual(relayer.main, "companion-impl")

        // Release restores priority
        release()
        XCTAssertEqual(relayer.main, "mrp-impl")
    }

    func testRelayerTakeoverNonexistent() {
        let relayer = Relayer<String>()

        relayer.register("mrp-impl", for: .mrp)

        // Takeover to non-existent protocol returns nil for main
        let release = relayer.takeover(.companion)
        XCTAssertNil(relayer.main)

        release()
        XCTAssertEqual(relayer.main, "mrp-impl")
    }

    // MARK: - All implementations

    func testRelayerAll() {
        let relayer = Relayer<String>()

        relayer.register("companion-impl", for: .companion)
        relayer.register("mrp-impl", for: .mrp)

        let all = relayer.all
        XCTAssertEqual(all.count, 2)
        // Priority order: MRP first, then Companion
        XCTAssertEqual(all[0], "mrp-impl")
        XCTAssertEqual(all[1], "companion-impl")
    }

    // MARK: - No implementations

    func testRelayerEmpty() {
        let relayer = Relayer<String>()
        XCTAssertNil(relayer.main)
        XCTAssertFalse(relayer.hasImplementations)
        XCTAssertTrue(relayer.all.isEmpty)
    }

    func testRelayerHasImplementations() {
        let relayer = Relayer<String>()
        XCTAssertFalse(relayer.hasImplementations)

        relayer.register("mrp-impl", for: .mrp)
        XCTAssertTrue(relayer.hasImplementations)
    }

    // MARK: - Registered protocols

    func testRelayerRegisteredProtocols() {
        let relayer = Relayer<String>()

        relayer.register("companion-impl", for: .companion)
        relayer.register("mrp-impl", for: .mrp)

        let protocols = relayer.registeredProtocols
        XCTAssertEqual(protocols.count, 2)
        // Should be in priority order
        XCTAssertEqual(protocols[0], .mrp)
        XCTAssertEqual(protocols[1], .companion)
    }

    // MARK: - Replace registration

    func testRelayerReplaceRegistration() {
        let relayer = Relayer<String>()

        relayer.register("mrp-v1", for: .mrp)
        XCTAssertEqual(relayer.main, "mrp-v1")

        relayer.register("mrp-v2", for: .mrp)
        XCTAssertEqual(relayer.main, "mrp-v2")
        XCTAssertEqual(relayer.all.count, 1)
    }

    // MARK: - Custom priorities

    func testRelayerCustomPriorities() {
        let relayer = Relayer<String>(priorities: [.companion, .mrp])

        relayer.register("mrp-impl", for: .mrp)
        relayer.register("companion-impl", for: .companion)

        // Companion has higher priority in this custom order
        XCTAssertEqual(relayer.main, "companion-impl")
    }
}
