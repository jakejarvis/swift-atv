import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/protocols/mrp/test_player_state.py
final class MRPPlayerStateTests: XCTestCase {

    // MARK: - Basic state

    func testDefaultState() {
        let state = MRPPlayerState()
        let playing = state.currentPlaying

        XCTAssertEqual(playing.mediaType, .unknown)
        XCTAssertEqual(playing.deviceState, .idle)
        XCTAssertNil(playing.title)
        XCTAssertNil(playing.artist)
    }

    // MARK: - Message Dispatcher

    func testMessageDispatcherRegisterAndDispatch() async {
        let dispatcher = MessageDispatcher<String, String>()
        var received: [String] = []

        await dispatcher.listen(to: "type1") { message in
            received.append(message)
        }

        await dispatcher.dispatch("type1", message: "hello")
        XCTAssertEqual(received, ["hello"])

        await dispatcher.dispatch("type2", message: "world")
        XCTAssertEqual(received, ["hello"]) // type2 not registered
    }

    func testMessageDispatcherMultipleHandlers() async {
        let dispatcher = MessageDispatcher<String, Int>()
        var received1: [Int] = []
        var received2: [Int] = []

        await dispatcher.listen(to: "count") { msg in
            received1.append(msg)
        }
        await dispatcher.listen(to: "count") { msg in
            received2.append(msg)
        }

        await dispatcher.dispatch("count", message: 42)
        XCTAssertEqual(received1, [42])
        XCTAssertEqual(received2, [42])
    }

    func testMessageDispatcherRemoveHandler() async {
        let dispatcher = MessageDispatcher<String, String>()
        var received: [String] = []

        let id = await dispatcher.listen(to: "test") { msg in
            received.append(msg)
        }

        await dispatcher.dispatch("test", message: "first")
        XCTAssertEqual(received.count, 1)

        await dispatcher.removeHandler(id)
        await dispatcher.dispatch("test", message: "second")
        XCTAssertEqual(received.count, 1) // handler removed
    }

    func testMessageDispatcherRemoveAllHandlers() async {
        let dispatcher = MessageDispatcher<String, String>()
        var count = 0

        await dispatcher.listen(to: "a") { _ in count += 1 }
        await dispatcher.listen(to: "b") { _ in count += 1 }

        await dispatcher.removeAllHandlers()

        await dispatcher.dispatch("a", message: "x")
        await dispatcher.dispatch("b", message: "y")
        XCTAssertEqual(count, 0)
    }

    func testMessageDispatcherDefaultHandler() async {
        let dispatcher = MessageDispatcher<String, String>()
        var defaultReceived: [String] = []

        await dispatcher.listenAll { msg in
            defaultReceived.append(msg)
        }

        await dispatcher.dispatch("any_type", message: "hello")
        await dispatcher.dispatch("other_type", message: "world")

        XCTAssertEqual(defaultReceived, ["hello", "world"])
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
        var received: [Int] = []

        await dispatcher.listen(
            to: "numbers",
            filter: { $0 > 5 }
        ) { msg in
            received.append(msg)
        }

        await dispatcher.dispatch("numbers", message: 3)
        await dispatcher.dispatch("numbers", message: 7)
        await dispatcher.dispatch("numbers", message: 1)
        await dispatcher.dispatch("numbers", message: 10)

        XCTAssertEqual(received, [7, 10])
    }
}
