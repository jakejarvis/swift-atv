import SwiftProtobuf
import XCTest

@testable import SwiftATV

/// Thread-safe accumulator for use in @Sendable test closures.
private final class Accumulator<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _values.count
    }

    func append(_ value: T) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private final class FakeMRPProtocolHandler: MRPProtocolHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshCount = 0
    let playing: Playing

    var refreshCount: Int {
        lock.withLock { _refreshCount }
    }

    init(playing: Playing) {
        self.playing = playing
    }

    func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? {
        nil
    }

    func refreshPlaying() async throws(ATVError) -> Playing {
        lock.withLock {
            _refreshCount += 1
        }
        return playing
    }
}

private final class RecordingMRPTransport: MRPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [ProtocolMessageMessage] = []

    weak var delegate: MRPConnectionDelegate?

    var messageStream: AsyncStream<ProtocolMessageMessage> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    var sentMessages: [ProtocolMessageMessage] {
        lock.withLock { _sentMessages }
    }

    func connect() async throws(ATVError) {}

    func enableEncryption(outputKey: Data, inputKey: Data) {}

    func send(_ message: ProtocolMessageMessage) async throws(ATVError) {
        lock.withLock {
            _sentMessages.append(message)
        }
    }

    func sendAndReceive(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum?,
        timeout: TimeInterval
    ) async throws(ATVError) -> ProtocolMessageMessage {
        lock.withLock {
            _sentMessages.append(message)
        }

        var response = ProtocolMessageMessage()
        response.type = responseType ?? message.type
        if response.type == .genericMessage {
            response.genericMessage = GenericMessage()
        }
        return response
    }

    func close() async {}
}

private final class ClientUpdatesErrorMRPTransport: MRPTransport, @unchecked Sendable {
    let clientUpdatesError: ATVError
    private let lock = NSLock()
    private var _sentTypes: [ProtocolMessageMessage.TypeEnum] = []

    weak var delegate: MRPConnectionDelegate?

    var messageStream: AsyncStream<ProtocolMessageMessage> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    var sentTypes: [ProtocolMessageMessage.TypeEnum] {
        lock.withLock { _sentTypes }
    }

    init(clientUpdatesError: ATVError) {
        self.clientUpdatesError = clientUpdatesError
    }

    func connect() async throws(ATVError) {}

    func enableEncryption(outputKey: Data, inputKey: Data) {}

    func send(_ message: ProtocolMessageMessage) async throws(ATVError) {
        lock.withLock {
            _sentTypes.append(message.type)
        }
    }

    func sendAndReceive(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum?,
        timeout: TimeInterval
    ) async throws(ATVError) -> ProtocolMessageMessage {
        lock.withLock {
            _sentTypes.append(message.type)
        }

        if message.type == .clientUpdatesConfigMessage {
            throw clientUpdatesError
        }

        var response = ProtocolMessageMessage()
        response.type = responseType ?? message.type
        if response.type == .deviceInfoMessage {
            response.deviceInfoMessage = DeviceInfoMessage()
        } else if response.type == .getKeyboardSessionMessage {
            response.getKeyboardSessionMessage = ""
        } else if response.type == .genericMessage {
            response.genericMessage = GenericMessage()
        }
        return response
    }

    func close() async {}
}

/// Ported from pyatv tests/protocols/mrp/test_player_state.py
final class MRPPlayerStateTests: XCTestCase {

    // MARK: - Basic state

    func testDefaultState() async {
        let state = MRPPlayerState()
        let playing = await state.currentPlaying

        XCTAssertEqual(playing.mediaType, .unknown)
        XCTAssertEqual(playing.deviceState, .idle)
        XCTAssertNil(playing.title)
        XCTAssertNil(playing.artist)
    }

    func testMRPMetadataPlayingRefreshesProtocolState() async throws {
        let refreshed = Playing(mediaType: .video, deviceState: .playing, title: "Fresh")
        let handler = FakeMRPProtocolHandler(playing: refreshed)
        let metadata = MRPMetadata(
            protocol: handler,
            playerState: MRPPlayerState(),
            stateStore: MRPStateStore()
        )

        let playing = try await metadata.playing()

        XCTAssertEqual(handler.refreshCount, 1)
        XCTAssertEqual(playing, refreshed)
    }

    func testPushUpdaterRejectsTooLargeInitialDelayWithoutOverflow() async {
        let updater = MRPPushUpdater(playerState: MRPPlayerState())

        do {
            try await updater.start(initialDelay: Int.max)
            XCTFail("Expected invalidConfig")
        } catch {
            guard case .invalidConfig = error else {
                XCTFail("Expected invalidConfig, got \(error)")
                return
            }
        }
    }

    func testMRPMessageTimestampConvertsSecondsToMicros() {
        XCTAssertEqual(MRPMessages.timestampMicros(from: 1.5), 1_500_000)
    }

    func testMRPMessageTimestampClampsInvalidWallClockValues() {
        XCTAssertEqual(MRPMessages.timestampMicros(from: -1), 0)
        XCTAssertEqual(MRPMessages.timestampMicros(from: Double.nan), 0)
        XCTAssertEqual(MRPMessages.timestampMicros(from: Double.infinity), 0)
        XCTAssertEqual(MRPMessages.timestampMicros(from: Double.greatestFiniteMagnitude), UInt64.max)
    }

    func testMRPBaseMessagesUsePyatvEnvelopeShape() {
        let message = MRPMessages.generic()

        XCTAssertEqual(message.type, .genericMessage)
        XCTAssertFalse(message.hasIdentifier)
        XCTAssertTrue(message.hasUniqueIdentifier)
        XCTAssertFalse(message.uniqueIdentifier.isEmpty)
        XCTAssertTrue(message.hasErrorCode)
        XCTAssertEqual(message.errorCode, .noError)
    }

    func testVarintRoundTrip() throws {
        let values = [0, 1, 127, 128, 300, 16_384, Int(UInt32.max)]

        for value in values {
            let encoded = MRPVarint.encode(value)
            var offset = 0
            let decoded = try MRPVarint.decode(encoded, offset: &offset)

            XCTAssertEqual(decoded, value)
            XCTAssertEqual(offset, encoded.count)
        }

        XCTAssertEqual(MRPVarint.encode(300), Data([0xAC, 0x02]))
    }

    func testVarintIncompleteReturnsNilWithoutAdvancingOffset() throws {
        var offset = 0

        let decoded = try MRPVarint.decode(Data([0x80]), offset: &offset)

        XCTAssertNil(decoded)
        XCTAssertEqual(offset, 0)
    }

    func testVarintTooLongThrows() {
        var offset = 0
        let invalid = Data(repeating: 0x80, count: 10)

        XCTAssertThrowsError(try MRPVarint.decode(invalid, offset: &offset))
    }

    func testVarintOverflowThrows() {
        var offset = 0
        var invalid = Data(repeating: 0xFF, count: 9)
        invalid.append(0x7F)

        XCTAssertThrowsError(try MRPVarint.decode(invalid, offset: &offset))
    }

    func testDeviceInformationMessageSerializesWithExtension() throws {
        let settings = ATVSettings(
            clientIdentity: ClientIdentitySettings(name: "Clicker", pairingIdentifier: "remote-id")
        )

        let message = MRPMessages.deviceInformation(settings: settings)
        let decoded = try ProtocolMessageMessage(
            serializedBytes: message.serializedData(),
            extensions: DeviceInfoMessage_Extensions
        )

        XCTAssertEqual(decoded.type, .deviceInfoMessage)
        XCTAssertEqual(decoded.deviceInfoMessage.name, "Clicker")
        XCTAssertEqual(decoded.deviceInfoMessage.uniqueIdentifier, "remote-id")
        XCTAssertEqual(decoded.deviceInfoMessage.applicationBundleIdentifier, "com.apple.TVRemote")
        XCTAssertEqual(decoded.deviceInfoMessage.deviceClass, .iPhone)
        XCTAssertTrue(decoded.deviceInfoMessage.supportsSystemPairing)
    }

    func testSetVolumeNormalizesPercentToProtocolRange() {
        let message = MRPMessages.setVolume(55, deviceID: "speaker-1")

        XCTAssertEqual(message.type, .setVolumeMessage)
        XCTAssertEqual(message.setVolumeMessage.outputDeviceUid, "speaker-1")
        XCTAssertEqual(message.setVolumeMessage.volume, 0.55, accuracy: 0.0001)
    }

    func testSetVolumeClampsPercentRange() {
        XCTAssertEqual(MRPMessages.setVolume(-10, deviceID: nil).setVolumeMessage.volume, 0)
        XCTAssertEqual(MRPMessages.setVolume(125, deviceID: nil).setVolumeMessage.volume, 1)
        XCTAssertEqual(MRPMessages.setVolume(.nan, deviceID: nil).setVolumeMessage.volume, 0)
        XCTAssertEqual(MRPMessages.setVolume(.infinity, deviceID: nil).setVolumeMessage.volume, 0)
    }

    func testHIDEventPayloadMatchesPyatvLayout() {
        let message = MRPMessages.hidEvent(usagePage: 0x000C, usage: 0x00E2, down: true)
        let bytes = [UInt8](message.sendHideventMessage.hidEventData)

        XCTAssertEqual(bytes.count, 60)
        XCTAssertEqual(Array(bytes[43..<49]), [0x00, 0x0C, 0x00, 0xE2, 0x00, 0x01])
        XCTAssertEqual(Array(bytes.suffix(11)), [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
    }

    func testSendHIDFlushesAfterEachTap() async throws {
        let transport = RecordingMRPTransport()
        let handler = Self.mrpProtocolHandler(transport: transport)

        try await handler.sendHID(usagePage: 1, usage: 0x89, action: .doubleTap)

        XCTAssertEqual(
            transport.sentMessages.map(\.type),
            [
                .sendHidEventMessage,
                .sendHidEventMessage,
                .genericMessage,
                .sendHidEventMessage,
                .sendHidEventMessage,
                .genericMessage,
            ]
        )
    }

    func testMRPAudioVolumeStepKeepsPyatvNoFlushBehavior() async throws {
        let transport = RecordingMRPTransport()
        let handler = Self.mrpProtocolHandler(transport: transport)
        let audio = MRPAudio(protocol: handler, stateStore: MRPStateStore())

        try await audio.volumeUp()

        XCTAssertEqual(
            transport.sentMessages.map(\.type),
            [.sendHidEventMessage, .sendHidEventMessage]
        )
    }

    func testPlaybackQueueRequestAsksForContentItemAssets() {
        let request = MRPMessages.playbackQueueRequest(
            width: 600,
            height: 400,
            playerPath: nil
        ).playbackQueueRequestMessage

        XCTAssertTrue(request.includeMetadata)
        XCTAssertTrue(request.returnContentItemAssetsInUserCompletion)
        XCTAssertEqual(request.artworkWidth, 600)
        XCTAssertEqual(request.artworkHeight, 400)
    }

    func testAddOutputDevicesUsesLegacyAndClusterAwareFields() {
        let message = MRPMessages.modifyOutputContext(adding: ["speaker-1", "speaker-2"])
        let inner = message.modifyOutputContextRequestMessage

        XCTAssertEqual(message.type, .modifyOutputContextRequestMessage)
        XCTAssertEqual(inner.type, .sharedAudioPresentation)
        XCTAssertEqual(inner.addingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.clusterAwareAddingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.removingDevices, [])
        XCTAssertEqual(inner.settingDevices, [])
        XCTAssertEqual(inner.clusterAwareRemovingDevices, [])
        XCTAssertEqual(inner.clusterAwareSettingDevices, [])
    }

    func testRemoveOutputDevicesUsesLegacyAndClusterAwareFields() {
        let message = MRPMessages.modifyOutputContext(removing: ["speaker-1", "speaker-2"])
        let inner = message.modifyOutputContextRequestMessage

        XCTAssertEqual(message.type, .modifyOutputContextRequestMessage)
        XCTAssertEqual(inner.type, .sharedAudioPresentation)
        XCTAssertEqual(inner.removingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.clusterAwareRemovingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.addingDevices, [])
        XCTAssertEqual(inner.settingDevices, [])
        XCTAssertEqual(inner.clusterAwareAddingDevices, [])
        XCTAssertEqual(inner.clusterAwareSettingDevices, [])
    }

    func testSetOutputDevicesUsesLegacyAndClusterAwareFields() {
        let message = MRPMessages.modifyOutputContext(setting: ["speaker-1", "speaker-2"])
        let inner = message.modifyOutputContextRequestMessage

        XCTAssertEqual(message.type, .modifyOutputContextRequestMessage)
        XCTAssertEqual(inner.type, .sharedAudioPresentation)
        XCTAssertEqual(inner.settingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.clusterAwareSettingDevices, ["speaker-1", "speaker-2"])
        XCTAssertEqual(inner.addingDevices, [])
        XCTAssertEqual(inner.removingDevices, [])
        XCTAssertEqual(inner.clusterAwareAddingDevices, [])
        XCTAssertEqual(inner.clusterAwareRemovingDevices, [])
    }

    func testValidateCommandResultThrowsOnSendError() {
        var result = SendCommandResultMessage()
        result.sendError = .notSupported

        XCTAssertThrowsError(
            try MRPProtocolHandler.validateCommandResult(result, command: .play)
        ) { error in
            guard case ATVError.protocolError = error else {
                XCTFail("Expected protocolError, got \(error)")
                return
            }
        }
    }

    func testValidateCommandResultThrowsOnHandlerFailure() {
        var result = SendCommandResultMessage()
        result.handlerReturnStatus = .commandFailed

        XCTAssertThrowsError(
            try MRPProtocolHandler.validateCommandResult(result, command: .pause)
        ) { error in
            guard case ATVError.protocolError = error else {
                XCTFail("Expected protocolError, got \(error)")
                return
            }
        }
    }

    func testValidatePairVerifyFinalResponseThrowsOnHAPError() {
        let errorTLV = TLV8.encode([TLV8.Entry(tag: .error, value: TLVError.authentication.rawValue)])

        XCTAssertThrowsError(try MRPProtocolHandler.validatePairVerifyFinalResponse(errorTLV)) { error in
            guard case ATVError.authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)")
                return
            }
        }
    }

    func testValidatePairVerifyFinalResponseRejectsMalformedTLV() {
        XCTAssertThrowsError(try MRPProtocolHandler.validatePairVerifyFinalResponse(Data([0x07, 0x02, 0x01]))) {
            error in
            guard case ATVError.invalidData = error else {
                XCTFail("Expected invalidData, got \(error)")
                return
            }
        }
    }

    func testSetStateUpdatesPlayingMetadataAndSupportedCommands() async {
        let state = MRPPlayerState()

        var play = CommandInfo()
        play.command = .play
        play.enabled = true

        var shuffle = CommandInfo()
        shuffle.command = .changeShuffleMode
        shuffle.enabled = true
        shuffle.shuffleMode = .songs

        var repeatMode = CommandInfo()
        repeatMode.command = .changeRepeatMode
        repeatMode.enabled = true
        repeatMode.repeatMode = .all

        var commands = SupportedCommands()
        commands.supportedCommands = [play, shuffle, repeatMode]

        await state.process(
            Self.setStateMessage(
                title: "Tunnel Vision",
                artist: "The Apples",
                album: "Remote Songs",
                commands: commands
            )
        )

        let playing = await state.currentPlaying

        XCTAssertEqual(playing.mediaType, .music)
        XCTAssertEqual(playing.deviceState, .playing)
        XCTAssertEqual(playing.title, "Tunnel Vision")
        XCTAssertEqual(playing.artist, "The Apples")
        XCTAssertEqual(playing.album, "Remote Songs")
        XCTAssertEqual(playing.totalTime, 245)
        XCTAssertEqual(playing.position, 42)
        XCTAssertEqual(playing.shuffle, .songs)
        XCTAssertEqual(playing.repeatState, .all)
        XCTAssertEqual(playing.contentIdentifier, "content-id")
        XCTAssertEqual(playing.iTunesStoreIdentifier, 123_456)
        XCTAssertEqual(playing.hash, "item-id")
        XCTAssertEqual(playing.app, App(name: "Music", identifier: "com.apple.TVMusic"))
        let artworkID = await state.artworkID
        let playCapabilityState = await state.capabilityState(for: .play)
        XCTAssertEqual(artworkID, "artwork-id")
        XCTAssertEqual(playCapabilityState, .available)
    }

    func testPausedPlaybackPositionDoesNotAdvanceFromTimestamp() async {
        let state = MRPPlayerState()
        var message = Self.setStateMessage(
            title: "Tunnel Vision",
            artist: "The Apples",
            album: "Remote Songs",
            commands: SupportedCommands()
        )
        var inner = message.setStateMessage
        inner.playbackState = .paused
        var item = inner.playbackQueue.contentItems[0]
        item.metadata.elapsedTime = 42
        item.metadata.elapsedTimeTimestamp = Self.cocoaTimestamp(secondsAgo: 120)
        item.metadata.playbackRate = 0
        inner.playbackQueue.contentItems = [item]
        message.setStateMessage = inner

        await state.process(message)

        let playing = await state.currentPlaying
        XCTAssertEqual(playing.deviceState, .paused)
        XCTAssertEqual(playing.position, 42)
    }

    func testPlayingPlaybackPositionAdvancesFromTimestamp() async {
        let state = MRPPlayerState()
        var message = Self.setStateMessage(
            title: "Tunnel Vision",
            artist: "The Apples",
            album: "Remote Songs",
            commands: SupportedCommands()
        )
        var inner = message.setStateMessage
        var item = inner.playbackQueue.contentItems[0]
        item.metadata.elapsedTime = 42
        item.metadata.elapsedTimeTimestamp = Self.cocoaTimestamp(secondsAgo: 120)
        item.metadata.playbackRate = 1
        inner.playbackQueue.contentItems = [item]
        message.setStateMessage = inner

        await state.process(message)

        let playing = await state.currentPlaying
        XCTAssertEqual(playing.deviceState, .playing)
        XCTAssertGreaterThanOrEqual(playing.position ?? 0, 150)
    }

    func testStoppedSetStateClearsStaleMetadata() async {
        let state = MRPPlayerState()
        await state.process(
            Self.setStateMessage(
                title: "Tunnel Vision",
                artist: "The Apples",
                album: "Remote Songs",
                commands: SupportedCommands()
            )
        )

        var stopped = Self.setStateMessage(
            title: "Tunnel Vision",
            artist: "The Apples",
            album: "Remote Songs",
            commands: SupportedCommands()
        )
        var inner = stopped.setStateMessage
        inner.playbackState = .stopped
        stopped.setStateMessage = inner
        await state.process(stopped)

        let playing = await state.currentPlaying
        let artworkID = await state.artworkID

        XCTAssertEqual(playing.deviceState, .stopped)
        XCTAssertEqual(playing.mediaType, .unknown)
        XCTAssertNil(playing.title)
        XCTAssertNil(playing.artist)
        XCTAssertNil(playing.album)
        XCTAssertNil(playing.hash)
        XCTAssertEqual(artworkID, "")
    }

    func testContentItemUpdateMergesPartialMetadataForCurrentItem() async {
        let state = MRPPlayerState()
        let setState = Self.setStateMessage(
            title: "Tunnel Vision",
            artist: "The Apples",
            album: "Remote Songs",
            commands: SupportedCommands()
        )
        await state.process(setState)

        await state.process(
            Self.updateContentItemMessage(
                identifier: "item-id",
                playerPath: setState.setStateMessage.playerPath
            ) { metadata in
                metadata.elapsedTime = 100
            }
        )

        let playing = await state.currentPlaying

        XCTAssertEqual(playing.title, "Tunnel Vision")
        XCTAssertEqual(playing.artist, "The Apples")
        XCTAssertEqual(playing.album, "Remote Songs")
        XCTAssertEqual(playing.position, 100)
        XCTAssertEqual(playing.hash, "item-id")
    }

    func testContentItemUpdateIgnoresUnrelatedItemIdentifier() async {
        let state = MRPPlayerState()
        let setState = Self.setStateMessage(
            title: "Tunnel Vision",
            artist: "The Apples",
            album: "Remote Songs",
            commands: SupportedCommands()
        )
        await state.process(setState)

        await state.process(
            Self.updateContentItemMessage(
                identifier: "other-item-id",
                playerPath: setState.setStateMessage.playerPath
            ) { metadata in
                metadata.title = "Wrong Item"
                metadata.trackArtistName = "Wrong Artist"
            }
        )

        let playing = await state.currentPlaying

        XCTAssertEqual(playing.title, "Tunnel Vision")
        XCTAssertEqual(playing.artist, "The Apples")
        XCTAssertEqual(playing.hash, "item-id")
    }

    func testSetStateIgnoresNonFinitePlaybackTimes() async {
        let state = MRPPlayerState()
        var message = Self.setStateMessage(
            title: "Bad Time",
            artist: "Artist",
            album: "Album",
            commands: SupportedCommands()
        )
        var item = message.setStateMessage.playbackQueue.contentItems[0]
        item.metadata.duration = .nan
        item.metadata.elapsedTime = .infinity
        message.setStateMessage.playbackQueue.contentItems = [item]

        await state.process(message)
        let playing = await state.currentPlaying

        XCTAssertNil(playing.totalTime)
        XCTAssertNil(playing.position)
    }

    // MARK: - Message Dispatcher

    func testMessageDispatcherRegisterAndDispatch() async {
        let dispatcher = MessageDispatcher<String, String>()
        let received = Accumulator<String>()

        await dispatcher.listen(to: "type1") { message in
            received.append(message)
        }

        await dispatcher.dispatch("type1", message: "hello")
        XCTAssertEqual(received.values, ["hello"])

        await dispatcher.dispatch("type2", message: "world")
        XCTAssertEqual(received.values, ["hello"])  // type2 not registered
    }

    func testMessageDispatcherMultipleHandlers() async {
        let dispatcher = MessageDispatcher<String, Int>()
        let received1 = Accumulator<Int>()
        let received2 = Accumulator<Int>()

        await dispatcher.listen(to: "count") { msg in
            received1.append(msg)
        }
        await dispatcher.listen(to: "count") { msg in
            received2.append(msg)
        }

        await dispatcher.dispatch("count", message: 42)
        XCTAssertEqual(received1.values, [42])
        XCTAssertEqual(received2.values, [42])
    }

    func testMessageDispatcherRemoveHandler() async {
        let dispatcher = MessageDispatcher<String, String>()
        let received = Accumulator<String>()

        let id = await dispatcher.listen(to: "test") { msg in
            received.append(msg)
        }

        await dispatcher.dispatch("test", message: "first")
        XCTAssertEqual(received.count, 1)

        await dispatcher.removeHandler(id)
        await dispatcher.dispatch("test", message: "second")
        XCTAssertEqual(received.count, 1)  // handler removed
    }

    func testMessageDispatcherRemoveAllHandlers() async {
        let dispatcher = MessageDispatcher<String, String>()
        let counter = Accumulator<String>()

        await dispatcher.listen(to: "a") { _ in counter.append("a") }
        await dispatcher.listen(to: "b") { _ in counter.append("b") }

        await dispatcher.removeAllHandlers()

        await dispatcher.dispatch("a", message: "x")
        await dispatcher.dispatch("b", message: "y")
        XCTAssertEqual(counter.count, 0)
    }

    func testMessageDispatcherDefaultHandler() async {
        let dispatcher = MessageDispatcher<String, String>()
        let received = Accumulator<String>()

        await dispatcher.listenAll { msg in
            received.append(msg)
        }

        await dispatcher.dispatch("any_type", message: "hello")
        await dispatcher.dispatch("other_type", message: "world")

        XCTAssertEqual(received.values, ["hello", "world"])
    }

    func testMessageDispatcherHasHandlers() async {
        let dispatcher = MessageDispatcher<String, String>()

        let hasNone = await dispatcher.hasHandlers(for: "test")
        XCTAssertFalse(hasNone)

        await dispatcher.listen(to: "test") { _ in }

        let hasOne = await dispatcher.hasHandlers(for: "test")
        XCTAssertTrue(hasOne)

        let hasOther = await dispatcher.hasHandlers(for: "other")
        XCTAssertFalse(hasOther)
    }

    func testMessageDispatcherFilter() async {
        let dispatcher = MessageDispatcher<String, Int>()
        let received = Accumulator<Int>()

        await dispatcher.listen(
            to: "numbers",
            filter: { $0 > 5 },
            handler: { msg in received.append(msg) }
        )

        await dispatcher.dispatch("numbers", message: 3)
        await dispatcher.dispatch("numbers", message: 7)
        await dispatcher.dispatch("numbers", message: 1)
        await dispatcher.dispatch("numbers", message: 10)

        XCTAssertEqual(received.values, [7, 10])
    }

    func testMRPCapabilitiesGateAudioControlsUntilVolumeStateArrives() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volume)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)

        stateStore.update(message: Self.volumeDidChangeMessage(volume: 0.42))

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volume)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)
    }

    func testMRPCapabilitiesHonorVolumeControlCapabilities() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                localDeviceUID: "local-device",
                clusterID: "cluster-device",
                groupedDevices: []
            )
        )

        stateStore.update(message: Self.volumeControlAvailabilityMessage(available: true, capabilities: .absolute))

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeUp)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeDown)).state, .available)

        stateStore.update(message: Self.volumeControlAvailabilityMessage(available: true, capabilities: .relative))

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeUp)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeDown)).state, .available)

        stateStore.update(message: Self.volumeControlAvailabilityMessage(available: false, capabilities: .both))

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeUp)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volumeDown)).state, .unavailable)
    }

    func testMRPCapabilitiesIgnoreVolumeControlUpdatesForOtherDevices() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                localDeviceUID: "local-device",
                groupedDevices: []
            )
        )

        stateStore.update(
            message: Self.volumeCapabilitiesDidChangeMessage(
                outputDeviceID: "other-device",
                available: true,
                capabilities: .absolute
            )
        )

        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)
    }

    func testMRPStateStorePrefersClusterAwareOutputDeviceUpdates() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        stateStore.update(
            message: Self.updateOutputDevicesMessage(
                outputDevices: [Self.outputDeviceDescriptor(identifier: "legacy", name: "Legacy", volume: 0.2)],
                clusterAwareOutputDevices: [
                    Self.outputDeviceDescriptor(identifier: "cluster", name: "Cluster", volume: 0.35)
                ]
            )
        )

        XCTAssertEqual(
            stateStore.outputDevices,
            [OutputDevice(identifier: "cluster", name: "Cluster", volume: 35)]
        )
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.outputDevices)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.addOutputDevices)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.removeOutputDevices)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setOutputDevices)).state, .available)
    }

    func testMRPStateStoreFallsBackToLegacyOutputDeviceUpdates() {
        let stateStore = MRPStateStore()

        stateStore.update(
            message: Self.updateOutputDevicesMessage(
                outputDevices: [Self.outputDeviceDescriptor(identifier: "legacy", name: "Legacy", volume: 0.2)],
                clusterAwareOutputDevices: []
            )
        )

        XCTAssertEqual(
            stateStore.outputDevices,
            [OutputDevice(identifier: "legacy", name: "Legacy", volume: 20)]
        )
    }

    func testMRPStateStoreDerivesOutputDevicesFromDeviceInfo() {
        let stateStore = MRPStateStore()

        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                groupedDevices: [Self.groupedDeviceInfo(identifier: "homepod", name: "HomePod")]
            )
        )

        XCTAssertEqual(
            stateStore.outputDevices,
            [
                OutputDevice(identifier: "local", name: "Apple TV"),
                OutputDevice(identifier: "homepod", name: "HomePod"),
            ]
        )
    }

    func testMRPStateStoreFiltersVolumeUpdatesByLocalDeviceID() {
        let stateStore = MRPStateStore()

        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                localDeviceUID: "local-device",
                groupedDevices: [Self.groupedDeviceInfo(identifier: "homepod", name: "HomePod")]
            )
        )

        stateStore.update(message: Self.volumeDidChangeMessage(volume: 0.33, outputDeviceID: "homepod"))

        XCTAssertEqual(stateStore.volume, 0)
        XCTAssertEqual(
            stateStore.outputDevices,
            [
                OutputDevice(identifier: "local", name: "Apple TV"),
                OutputDevice(identifier: "homepod", name: "HomePod", volume: 33),
            ]
        )

        stateStore.update(message: Self.volumeDidChangeMessage(volume: 0.44, outputDeviceID: "local-device"))

        XCTAssertEqual(stateStore.volume, 44)
    }

    func testMRPStateStoreClampsInboundVolumeRange() {
        let stateStore = MRPStateStore()

        stateStore.update(message: Self.volumeDidChangeMessage(volume: -0.25))

        XCTAssertEqual(stateStore.volume, 0)
        XCTAssertTrue(stateStore.hasVolumeState)

        stateStore.update(message: Self.volumeDidChangeMessage(volume: 1.25))

        XCTAssertEqual(stateStore.volume, 100)
    }

    func testMRPStateStoreIgnoresNonFiniteInboundVolume() {
        let stateStore = MRPStateStore()

        stateStore.update(message: Self.volumeDidChangeMessage(volume: .nan))

        XCTAssertFalse(stateStore.hasVolumeState)
        XCTAssertEqual(stateStore.volume, 0)

        stateStore.update(message: Self.volumeDidChangeMessage(volume: 0.42))
        stateStore.update(message: Self.volumeDidChangeMessage(volume: .infinity))

        XCTAssertEqual(stateStore.volume, 42)
    }

    func testMRPAudioSetVolumeUsesLocalVolumeDeviceID() async throws {
        let transport = RecordingMRPTransport()
        let handler = Self.mrpProtocolHandler(transport: transport)
        let stateStore = MRPStateStore()
        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                localDeviceUID: "local-device",
                clusterID: "cluster-device",
                groupedDevices: []
            )
        )
        let audio = MRPAudio(protocol: handler, stateStore: stateStore)

        try await audio.setVolume(55, device: nil)

        XCTAssertEqual(transport.sentMessages.map(\.type), [.setVolumeMessage])
        XCTAssertEqual(transport.sentMessages[0].setVolumeMessage.outputDeviceUid, "cluster-device")
        XCTAssertEqual(transport.sentMessages[0].setVolumeMessage.volume, 0.55, accuracy: 0.0001)
    }

    func testMRPAudioAbsoluteVolumeStepUsesSetVolume() async throws {
        let transport = RecordingMRPTransport()
        let handler = Self.mrpProtocolHandler(transport: transport)
        let stateStore = MRPStateStore()
        stateStore.update(
            message: Self.deviceInfoMessage(
                localIdentifier: "local",
                localName: "Apple TV",
                localDeviceUID: "local-device",
                clusterID: "cluster-device",
                groupedDevices: []
            )
        )
        stateStore.update(message: Self.volumeDidChangeMessage(volume: 0.4, outputDeviceID: "cluster-device"))
        stateStore.update(message: Self.volumeControlAvailabilityMessage(available: true, capabilities: .absolute))
        let audio = MRPAudio(protocol: handler, stateStore: stateStore)

        try await audio.volumeUp()

        XCTAssertEqual(transport.sentMessages.map(\.type), [.setVolumeMessage])
        XCTAssertEqual(transport.sentMessages[0].setVolumeMessage.outputDeviceUid, "cluster-device")
        XCTAssertEqual(transport.sentMessages[0].setVolumeMessage.volume, 0.45, accuracy: 0.0001)
    }

    func testMRPStateStoreSkipsOutputDevicesWithEmptyIdentifiers() {
        let stateStore = MRPStateStore()

        stateStore.update(
            message: Self.updateOutputDevicesMessage(
                outputDevices: [
                    Self.outputDeviceDescriptor(identifier: "", name: "Missing ID", volume: 0.5),
                    Self.outputDeviceDescriptor(identifier: "speaker", name: "Speaker", volume: 0.5),
                ],
                clusterAwareOutputDevices: []
            )
        )

        XCTAssertEqual(
            stateStore.outputDevices,
            [OutputDevice(identifier: "speaker", name: "Speaker", volume: 50)]
        )
    }

    func testMRPStateStoreSanitizesOutputDeviceVolumes() {
        let stateStore = MRPStateStore()

        stateStore.update(
            message: Self.updateOutputDevicesMessage(
                outputDevices: [
                    Self.outputDeviceDescriptor(identifier: "low", name: "Low", volume: -0.25),
                    Self.outputDeviceDescriptor(identifier: "high", name: "High", volume: 1.25),
                    Self.outputDeviceDescriptor(identifier: "invalid", name: "Invalid", volume: .nan),
                ],
                clusterAwareOutputDevices: []
            )
        )

        XCTAssertEqual(
            stateStore.outputDevices,
            [
                OutputDevice(identifier: "low", name: "Low", volume: 0),
                OutputDevice(identifier: "high", name: "High", volume: 100),
                OutputDevice(identifier: "invalid", name: "Invalid", volume: 0),
            ]
        )
    }

    func testMRPCapabilitiesExposeOptionalSetupDiagnostics() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        stateStore.recordSetupFailure("client updates failed", affectedCapabilities: [.push(.updates)])

        let info = capabilities.capabilityInfo(.push(.updates))
        XCTAssertEqual(info.state, .unavailable)
        XCTAssertEqual(info.options["diagnostic"], "client updates failed")
    }

    func testMRPSetupPropagatesConnectionLostDuringOptionalClientUpdates() async throws {
        let transport = ClientUpdatesErrorMRPTransport(
            clientUpdatesError: .connectionLost("closed during client updates")
        )
        let stateStore = MRPStateStore()
        let handler = MRPProtocolHandler(
            connection: transport,
            playerState: MRPPlayerState(),
            stateStore: stateStore,
            authenticationMode: .alreadySecure,
            heartbeatMode: .disabled,
            runtimeRequestTimeout: 0.1
        )

        do {
            try await handler.start(settings: ATVSettings(), credentials: nil, requestTimeout: 0.1)
            XCTFail("Expected connectionLost")
        } catch let error {
            guard case .connectionLost = error else {
                XCTFail("Expected connectionLost, got \(error)")
                return
            }
        }

        XCTAssertTrue(stateStore.setupDiagnosticEntries().isEmpty)
        XCTAssertEqual(
            transport.sentTypes,
            [.deviceInfoMessage, .setConnectionStateMessage, .clientUpdatesConfigMessage]
        )
    }

    func testMRPSetupKeepsRecoverableClientUpdateFailureAsDiagnostics() async throws {
        let timeout = ATVError.operationTimeout(
            TimeoutContext(
                protocol: .mrp,
                operation: "request",
                requestID: "client-updates",
                duration: 0.1
            ))
        let transport = ClientUpdatesErrorMRPTransport(clientUpdatesError: timeout)
        let stateStore = MRPStateStore()
        let handler = MRPProtocolHandler(
            connection: transport,
            playerState: MRPPlayerState(),
            stateStore: stateStore,
            authenticationMode: .alreadySecure,
            heartbeatMode: .disabled,
            runtimeRequestTimeout: 0.1
        )

        try await handler.start(settings: ATVSettings(), credentials: nil, requestTimeout: 0.1)

        let diagnostics = stateStore.setupDiagnosticEntries()
        XCTAssertTrue(diagnostics.contains { $0.0 == .push(.updates) })
        XCTAssertTrue(diagnostics.contains { $0.0 == .audio(.volume) })
        XCTAssertEqual(
            transport.sentTypes,
            [
                .deviceInfoMessage, .setConnectionStateMessage,
                .clientUpdatesConfigMessage, .getKeyboardSessionMessage,
            ]
        )
    }

    func testMRPCapabilitiesExposeSupportedMediaCommands() {
        let stateStore = MRPStateStore()
        let capabilities = MRPCapabilities(stateStore: stateStore)

        var play = CommandInfo()
        play.command = .play
        play.enabled = true
        play.localizedTitle = "Play"

        var pause = CommandInfo()
        pause.command = .pause
        pause.enabled = false

        var queue = CommandInfo()
        queue.command = .setPlaybackQueue
        queue.enabled = true

        var commands = SupportedCommands()
        commands.supportedCommands = [play, pause, queue]

        stateStore.update(
            message: Self.setStateMessage(
                title: "Title",
                artist: "Artist",
                album: "Album",
                commands: commands
            )
        )

        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.play)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.pause)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.setPlaybackQueue)).state, .unsupported)
        XCTAssertEqual(stateStore.commandInfo(.play)?.localizedTitle, "Play")
    }

    private static func setStateMessage(
        title: String,
        artist: String,
        album: String,
        commands: SupportedCommands
    ) -> ProtocolMessageMessage {
        var client = NowPlayingClient()
        client.bundleIdentifier = "com.apple.TVMusic"
        client.displayName = "Music"

        var player = NowPlayingPlayer()
        player.identifier = "MediaRemote-DefaultPlayer"
        player.displayName = "Default"
        player.isDefaultPlayer = true

        var path = PlayerPath()
        path.client = client
        path.player = player

        var metadata = ContentItemMetadata()
        metadata.title = title
        metadata.trackArtistName = artist
        metadata.albumName = album
        metadata.duration = 245
        metadata.elapsedTime = 42
        metadata.contentIdentifier = "content-id"
        metadata.iTunesStoreIdentifier = 123_456
        metadata.artworkIdentifier = "artwork-id"
        metadata.mediaType = .audio

        var item = ContentItem()
        item.identifier = "item-id"
        item.metadata = metadata

        var queue = PlaybackQueue()
        queue.contentItems = [item]

        var inner = SetStateMessage()
        inner.playerPath = path
        inner.playbackState = .playing
        inner.playbackQueue = queue
        inner.supportedCommands = commands

        var message = ProtocolMessageMessage()
        message.type = .setStateMessage
        message.setStateMessage = inner
        return message
    }

    private static func mrpProtocolHandler(transport: RecordingMRPTransport) -> MRPProtocolHandler {
        MRPProtocolHandler(
            connection: transport,
            playerState: MRPPlayerState(),
            stateStore: MRPStateStore(),
            authenticationMode: .alreadySecure,
            heartbeatMode: .disabled,
            runtimeRequestTimeout: 0.1
        )
    }

    private static func updateContentItemMessage(
        identifier: String,
        playerPath: PlayerPath,
        mutateMetadata: (inout ContentItemMetadata) -> Void
    ) -> ProtocolMessageMessage {
        var metadata = ContentItemMetadata()
        mutateMetadata(&metadata)

        var item = ContentItem()
        item.identifier = identifier
        item.metadata = metadata

        var inner = UpdateContentItemMessage()
        inner.playerPath = playerPath
        inner.contentItems = [item]

        var message = ProtocolMessageMessage()
        message.type = .updateContentItemMessage
        message.updateContentItemMessage = inner
        return message
    }

    private static func cocoaTimestamp(secondsAgo: TimeInterval) -> Double {
        Date().timeIntervalSince1970 - 978_307_200.0 - secondsAgo
    }

    private static func outputDeviceDescriptor(
        identifier: String,
        name: String,
        volume: Float
    ) -> AVOutputDeviceDescriptor {
        var descriptor = AVOutputDeviceDescriptor()
        descriptor.uniqueIdentifier = identifier
        descriptor.name = name
        descriptor.volume = volume
        return descriptor
    }

    private static func updateOutputDevicesMessage(
        outputDevices: [AVOutputDeviceDescriptor],
        clusterAwareOutputDevices: [AVOutputDeviceDescriptor]
    ) -> ProtocolMessageMessage {
        var update = UpdateOutputDeviceMessage()
        update.outputDevices = outputDevices
        update.clusterAwareOutputDevices = clusterAwareOutputDevices

        var message = ProtocolMessageMessage()
        message.type = .updateOutputDeviceMessage
        message.updateOutputDeviceMessage = update
        return message
    }

    private static func groupedDeviceInfo(identifier: String, name: String) -> DeviceInfoMessage {
        var info = DeviceInfoMessage()
        info.deviceUid = identifier
        info.name = name
        return info
    }

    private static func deviceInfoMessage(
        localIdentifier: String,
        localName: String,
        localDeviceUID: String? = nil,
        clusterID: String? = nil,
        groupedDevices: [DeviceInfoMessage]
    ) -> ProtocolMessageMessage {
        var info = DeviceInfoMessage()
        info.uniqueIdentifier = localIdentifier
        info.name = localName
        if let localDeviceUID {
            info.deviceUid = localDeviceUID
        }
        if let clusterID {
            info.clusterID = clusterID
        }
        info.isGroupLeader = true
        info.isProxyGroupPlayer = false
        info.groupedDevices = groupedDevices

        var message = ProtocolMessageMessage()
        message.type = .deviceInfoMessage
        message.deviceInfoMessage = info
        return message
    }

    private static func volumeDidChangeMessage(
        volume: Float,
        outputDeviceID: String? = nil
    ) -> ProtocolMessageMessage {
        var inner = VolumeDidChangeMessage()
        inner.volume = volume
        if let outputDeviceID {
            inner.outputDeviceUid = outputDeviceID
        }

        var message = ProtocolMessageMessage()
        message.type = .volumeDidChangeMessage
        message.volumeDidChangeMessage = inner
        return message
    }

    private static func volumeControlAvailabilityMessage(
        available: Bool,
        capabilities: VolumeCapabilities.Enum
    ) -> ProtocolMessageMessage {
        var inner = VolumeControlAvailabilityMessage()
        inner.volumeControlAvailable = available
        inner.volumeCapabilities = capabilities

        var message = ProtocolMessageMessage()
        message.type = .volumeControlAvailabilityMessage
        message.volumeControlAvailabilityMessage = inner
        return message
    }

    private static func volumeCapabilitiesDidChangeMessage(
        outputDeviceID: String,
        available: Bool,
        capabilities: VolumeCapabilities.Enum
    ) -> ProtocolMessageMessage {
        var inner = VolumeControlCapabilitiesDidChangeMessage()
        inner.outputDeviceUid = outputDeviceID
        var availability = VolumeControlAvailabilityMessage()
        availability.volumeControlAvailable = available
        availability.volumeCapabilities = capabilities
        inner.capabilities = availability

        var message = ProtocolMessageMessage()
        message.type = .volumeControlCapabilitiesDidChangeMessage
        message.volumeControlCapabilitiesDidChangeMessage = inner
        return message
    }
}
