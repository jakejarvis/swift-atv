import Foundation

/// Encoder/decoder for the RTI text-input archives carried in Companion
/// `_tiStart` and `_tiC` messages.
enum CompanionTextInputSession {
    struct State: Sendable, Equatable {
        let sessionUUID: Data
        let currentText: String
    }

    static func encodeInsertText(_ text: String, sessionUUID: Data) -> Data {
        typealias Object = BinaryPlistArchive.Object
        let objects: [Object] = [
            .string("$null"),
            .dictionary([
                ("keyboardOutput", .uid(2)),
                ("$class", .uid(7)),
                ("targetSessionUUID", .uid(5)),
            ]),
            .dictionary([
                ("insertionText", .uid(3)),
                ("$class", .uid(4)),
            ]),
            .string(text),
            .dictionary([
                ("$classname", .string("TIKeyboardOutput")),
                ("$classes", .stringArray(["TIKeyboardOutput", "NSObject"])),
            ]),
            .dictionary([
                ("NS.uuidbytes", .data(sessionUUID)),
                ("$class", .uid(6)),
            ]),
            .dictionary([
                ("$classname", .string("NSUUID")),
                ("$classes", .stringArray(["NSUUID", "NSObject"])),
            ]),
            .dictionary([
                ("$classname", .string("RTITextOperations")),
                ("$classes", .stringArray(["RTITextOperations", "NSObject"])),
            ]),
        ]

        return BinaryPlistArchive.make(
            archiver: "RTIKeyedArchiver",
            top: [("textOperations", .uid(1))],
            objects: objects
        )
    }

    static func encodeReplaceText(_ text: String, sessionUUID: Data) -> Data {
        typealias Object = BinaryPlistArchive.Object
        let objects: [Object] = [
            .string("$null"),
            .dictionary([
                ("$class", .uid(8)),
                ("targetSessionUUID", .uid(6)),
                ("keyboardOutput", .uid(2)),
                ("textToAssert", .uid(4)),
            ]),
            .dictionary([
                ("insertionText", .uid(3)),
                ("$class", .uid(5)),
            ]),
            .string(text),
            .string(""),
            .dictionary([
                ("$classname", .string("TIKeyboardOutput")),
                ("$classes", .stringArray(["TIKeyboardOutput", "NSObject"])),
            ]),
            .dictionary([
                ("NS.uuidbytes", .data(sessionUUID)),
                ("$class", .uid(7)),
            ]),
            .dictionary([
                ("$classname", .string("NSUUID")),
                ("$classes", .stringArray(["NSUUID", "NSObject"])),
            ]),
            .dictionary([
                ("$classname", .string("RTITextOperations")),
                ("$classes", .stringArray(["RTITextOperations", "NSObject"])),
            ]),
        ]

        return BinaryPlistArchive.make(
            archiver: "RTIKeyedArchiver",
            top: [("textOperations", .uid(1))],
            objects: objects
        )
    }

    static func decodeStartResponse(_ data: Data) throws(ATVError) -> State {
        let plist: [String: Any]
        do {
            guard
                let decoded = try PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                ) as? [String: Any]
            else {
                throw ATVError.invalidResponse("Companion text input response is not a keyed archive")
            }
            plist = decoded
        } catch let error as ATVError {
            throw error
        } catch {
            throw ATVError.invalidData("Companion text input response is not a valid binary plist")
        }

        guard let objects = plist["$objects"] as? [Any],
            let top = plist["$top"] as? [String: Any]
        else {
            throw ATVError.invalidResponse("Companion text input response is missing archive metadata")
        }

        guard let sessionIndex = uidValue(top["sessionUUID"]),
            sessionIndex < objects.count
        else {
            throw ATVError.invalidResponse("Companion text input response is missing session UUID")
        }

        let sessionUUID: Data
        if let data = objects[sessionIndex] as? Data {
            sessionUUID = data
        } else if let uuid = objects[sessionIndex] as? [String: Any],
            let data = uuid["NS.uuidbytes"] as? Data
        {
            sessionUUID = data
        } else {
            throw ATVError.invalidResponse("Companion text input response has invalid session UUID")
        }

        return State(
            sessionUUID: sessionUUID,
            currentText: documentText(from: top, objects: objects)
        )
    }

    static func uidValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any],
            let uid = dictionary["CF$UID"] as? Int
        {
            return uid
        }

        // PropertyListSerialization reads real binary plist UID objects as a
        // private CFKeyedArchiverUID type. Its description exposes the value.
        let description = String(describing: value)
        guard description.contains("CFKeyedArchiverUID"),
            let valueRange = description.range(of: "value = "),
            let end = description[valueRange.upperBound...].firstIndex(of: "}")
        else {
            return nil
        }
        return Int(description[valueRange.upperBound..<end].trimmingCharacters(in: .whitespaces))
    }

    static func testUID(_ index: Int) -> NSDictionary {
        ["CF$UID": index] as NSDictionary
    }

    private static func documentText(from top: [String: Any], objects: [Any]) -> String {
        guard let documentStateIndex = uidValue(top["documentState"]),
            documentStateIndex < objects.count,
            let documentState = objects[documentStateIndex] as? [String: Any],
            let innerStateIndex = uidValue(documentState["docSt"]),
            innerStateIndex < objects.count,
            let innerState = objects[innerStateIndex] as? [String: Any],
            let textIndex = uidValue(innerState["contextBeforeInput"]),
            textIndex < objects.count,
            let text = objects[textIndex] as? String
        else {
            return ""
        }
        return text
    }
}
