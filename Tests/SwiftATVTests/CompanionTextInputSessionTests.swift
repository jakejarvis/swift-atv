import Foundation
import Testing

@testable import SwiftATV

@Suite("Companion text input RTI archives")
struct CompanionTextInputSessionTests {
    private let sessionUUID = Data([
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C,
        0x0D, 0x0E, 0x0F, 0x10,
    ])

    @Test("Insert text archive uses RTIKeyedArchiver and preserves UUID")
    func insertTextArchive() throws {
        let data = CompanionTextInputSession.encodeInsertText("hello", sessionUUID: sessionUUID)
        let plist = try decode(data)

        #expect(plist["$archiver"] as? String == "RTIKeyedArchiver")
        #expect(plist["$version"] as? Int == 100_000)

        let objects = try #require(plist["$objects"] as? [Any])
        #expect(objects.contains { ($0 as? String) == "hello" })

        let textOperations = try #require(objects[1] as? [String: Any])
        let uuidIndex = try #require(CompanionTextInputSession.uidValue(textOperations["targetSessionUUID"]))
        let uuidObject = try #require(objects[uuidIndex] as? [String: Any])
        #expect(uuidObject["NS.uuidbytes"] as? Data == sessionUUID)
    }

    @Test("Replace text archive clears and inserts atomically")
    func replaceTextArchive() throws {
        let data = CompanionTextInputSession.encodeReplaceText("world", sessionUUID: sessionUUID)
        let plist = try decode(data)
        let objects = try #require(plist["$objects"] as? [Any])
        let textOperations = try #require(objects[1] as? [String: Any])

        let assertIndex = try #require(CompanionTextInputSession.uidValue(textOperations["textToAssert"]))
        #expect(objects[assertIndex] as? String == "")

        let keyboardIndex = try #require(CompanionTextInputSession.uidValue(textOperations["keyboardOutput"]))
        let keyboardOutput = try #require(objects[keyboardIndex] as? [String: Any])
        let textIndex = try #require(CompanionTextInputSession.uidValue(keyboardOutput["insertionText"]))
        #expect(objects[textIndex] as? String == "world")
    }

    @Test("Start response decoder extracts session UUID and current text")
    func decodeStartResponse() throws {
        let fixture = startResponseFixture(sessionUUID: sessionUUID, text: "existing text")
        let state = try CompanionTextInputSession.decodeStartResponse(fixture)

        #expect(state.sessionUUID == sessionUUID)
        #expect(state.currentText == "existing text")
    }

    @Test("Start response decoder requires a session UUID")
    func decodeStartResponseRequiresUUID() throws {
        let archive: [String: Any] = [
            "$archiver": "RTIKeyedArchiver",
            "$version": 100_000,
            "$top": [:] as NSDictionary,
            "$objects": ["$null"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive,
            format: .binary,
            options: 0
        )

        #expect(throws: ATVError.self) {
            _ = try CompanionTextInputSession.decodeStartResponse(data)
        }
    }

    @Test("Start response decoder rejects negative UID indexes")
    func decodeStartResponseRejectsNegativeUID() throws {
        let archive: [String: Any] = [
            "$archiver": "RTIKeyedArchiver",
            "$version": 100_000,
            "$top": ["sessionUUID": CompanionTextInputSession.testUID(-1)] as NSDictionary,
            "$objects": ["$null"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive,
            format: .binary,
            options: 0
        )

        #expect(throws: ATVError.self) {
            _ = try CompanionTextInputSession.decodeStartResponse(data)
        }
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func startResponseFixture(sessionUUID: Data, text: String) -> Data {
        let uid = CompanionTextInputSession.testUID
        let archive: [String: Any] = [
            "$archiver": "RTIKeyedArchiver",
            "$version": 100_000,
            "$top": [
                "documentState": uid(1),
                "sessionUUID": uid(6),
            ] as NSDictionary,
            "$objects": [
                "$null",
                [
                    "docSt": uid(2),
                    "$class": uid(5),
                ] as NSDictionary,
                [
                    "contextBeforeInput": uid(3),
                    "$class": uid(4),
                ] as NSDictionary,
                text,
                [
                    "$classname": "TIDocumentState",
                    "$classes": ["TIDocumentState", "NSObject"],
                ] as NSDictionary,
                [
                    "$classname": "RTIDocumentState",
                    "$classes": ["RTIDocumentState", "NSObject"],
                ] as NSDictionary,
                sessionUUID,
            ],
        ]

        return try! PropertyListSerialization.data(
            fromPropertyList: archive,
            format: .binary,
            options: 0
        )
    }
}
