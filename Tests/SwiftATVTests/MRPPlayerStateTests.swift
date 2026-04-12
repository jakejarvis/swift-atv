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

    func testDeviceInformationMessageSerializesWithExtension() throws {
        let settings = ATVSettings(
            info: InfoSettings(name: "Clicker", remotePairingID: "remote-id")
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
        let playFeatureState = await state.featureState(for: .play)
        XCTAssertEqual(artworkID, "artwork-id")
        XCTAssertEqual(playFeatureState, .available)
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
}
