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

    // MARK: - Facade command routing

    func testRelayingRemoteControlFallsBackAfterNotSupported() async throws {
        let relayer = Relayer<RemoteControl>()
        let mrp = StubRemoteControl(channelUpResult: .unsupported)
        let companion = StubRemoteControl(channelUpResult: .success)
        relayer.register(mrp, for: .mrp)
        relayer.register(companion, for: .companion)

        try await RelayingRemoteControl(relayer: relayer).channelUp()

        XCTAssertEqual(mrp.channelUpCalls, 1)
        XCTAssertEqual(companion.channelUpCalls, 1)
    }

    func testRelayingRemoteControlDoesNotFallbackAfterProtocolError() async {
        let relayer = Relayer<RemoteControl>()
        let mrp = StubRemoteControl(channelUpResult: .protocolError)
        let companion = StubRemoteControl(channelUpResult: .success)
        relayer.register(mrp, for: .mrp)
        relayer.register(companion, for: .companion)

        do {
            try await RelayingRemoteControl(relayer: relayer).channelUp()
            XCTFail("Expected channelUp to throw")
        } catch let error {
            guard case ATVError.protocolError = error else {
                XCTFail("Expected protocolError, got \(error)")
                return
            }
        }

        XCTAssertEqual(mrp.channelUpCalls, 1)
        XCTAssertEqual(companion.channelUpCalls, 0)
    }

    func testRelayingFeaturesUseLowerPriorityWhenHigherPriorityIsUnsupported() {
        let relayer = Relayer<FeatureProvider>()
        relayer.register(StubFeatures([.channelUp: .unsupported]), for: .mrp)
        relayer.register(StubFeatures([.channelUp: .available]), for: .companion)

        let features = RelayingFeatures(relayer: relayer)

        XCTAssertEqual(features.featureInfo(.channelUp).state, .available)
        XCTAssertTrue(features.isAvailable(.channelUp))
    }

    func testRelayingFeaturesKeepHigherPriorityUnavailableState() {
        let relayer = Relayer<FeatureProvider>()
        relayer.register(StubFeatures([.play: .unavailable]), for: .mrp)
        relayer.register(StubFeatures([.play: .available]), for: .companion)

        let features = RelayingFeatures(relayer: relayer)

        XCTAssertEqual(features.featureInfo(.play).state, .unavailable)
    }
}

private final class StubRemoteControl: @unchecked Sendable, RemoteControl {
    enum Result {
        case success
        case unsupported
        case protocolError
    }

    private let lock = NSLock()
    private let channelUpResult: Result
    private var _channelUpCalls = 0

    init(channelUpResult: Result) {
        self.channelUpResult = channelUpResult
    }

    var channelUpCalls: Int { lock.withLock { _channelUpCalls } }

    func channelUp() async throws(ATVError) {
        lock.withLock { _channelUpCalls += 1 }
        switch channelUpResult {
        case .success:
            return
        case .unsupported:
            throw ATVError.notSupported("unsupported")
        case .protocolError:
            throw ATVError.protocolError("failed")
        }
    }

    func up(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func down(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func left(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func right(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func play() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func playPause() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func pause() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func stop() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func next() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func previous() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func select(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func menu(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func volumeUp() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func volumeDown() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func home(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func homeHold() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func topMenu() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func suspend() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func wakeUp() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func skipForward(interval: TimeInterval) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func skipBackward(interval: TimeInterval) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func setPosition(_ position: Int) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func setShuffle(_ state: ShuffleState) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func setRepeat(_ state: RepeatState) async throws(ATVError) { throw ATVError.notSupported("unused") }
    func channelDown() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func screensaver() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func guide() async throws(ATVError) { throw ATVError.notSupported("unused") }
    func controlCenter() async throws(ATVError) { throw ATVError.notSupported("unused") }
}

private struct StubFeatures: FeatureProvider {
    let states: [FeatureName: FeatureState]

    init(_ states: [FeatureName: FeatureState]) {
        self.states = states
    }

    func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        FeatureInfo(state: states[feature] ?? .unsupported)
    }

    func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo] {
        Dictionary(
            uniqueKeysWithValues: FeatureName.allCases.compactMap { feature in
                let info = featureInfo(feature)
                if !includeUnsupported, info.state == .unsupported {
                    return nil
                }
                return (feature, info)
            })
    }

    func inState(_ states: [FeatureState], features: FeatureName...) -> Bool {
        features.allSatisfy { states.contains(featureInfo($0).state) }
    }
}
