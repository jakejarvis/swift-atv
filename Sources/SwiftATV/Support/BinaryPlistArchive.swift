import Foundation

/// Minimal binary property-list archive writer with native UID support.
///
/// `PropertyListSerialization` can read keyed archives containing UID objects,
/// but it cannot create those UID objects from Swift dictionaries. Companion
/// text input uses RTI keyed archives whose object graph depends on real UID
/// markers, so this writer covers the small subset SwiftATV needs: strings,
/// integers, data blobs, UID references, arrays of strings, and dictionaries.
enum BinaryPlistArchive {
    enum Object {
        case string(String)
        case int(Int)
        case data(Data)
        case uid(Int)
        case dictionary([(String, Object)])
        case stringArray([String])
    }

    static func make(
        archiver: String,
        top: [(String, Object)],
        objects archiveObjects: [Object]
    ) -> Data {
        var table = ObjectTable()

        let objectIndexes = archiveObjects.map { table.append($0) }
        let objectsArrayIndex = table.appendArray(objectIndexes)

        let topKeys = top.map { table.append(.string($0.0)) }
        let topValues = top.map { table.append($0.1) }
        let topIndex = table.appendDictionary(keys: topKeys, values: topValues)

        let rootKeys = [
            table.append(.string("$archiver")),
            table.append(.string("$objects")),
            table.append(.string("$top")),
            table.append(.string("$version")),
        ]
        let rootValues = [
            table.append(.string(archiver)),
            objectsArrayIndex,
            topIndex,
            table.append(.int(100_000)),
        ]
        let rootIndex = table.appendDictionary(keys: rootKeys, values: rootValues)

        return table.finalize(rootIndex: rootIndex)
    }
}

private struct ObjectTable {
    private enum Entry {
        case scalar(Data)
        case array([Int])
        case dictionary(keys: [Int], values: [Int])
    }

    private var entries: [Entry] = []

    mutating func append(_ object: BinaryPlistArchive.Object) -> Int {
        switch object {
        case .string(let string):
            return appendScalar(Self.encode(string: string))
        case .int(let value):
            return appendScalar(Self.encode(integer: value))
        case .data(let data):
            return appendScalar(Self.encode(data: data))
        case .uid(let index):
            return appendScalar(Self.encode(uid: index))
        case .stringArray(let strings):
            return appendArray(strings.map { append(.string($0)) })
        case .dictionary(let pairs):
            let index = entries.count
            entries.append(.scalar(Data()))
            let keys = pairs.map { append(.string($0.0)) }
            let values = pairs.map { append($0.1) }
            entries[index] = .dictionary(keys: keys, values: values)
            return index
        }
    }

    mutating func appendArray(_ indexes: [Int]) -> Int {
        let index = entries.count
        entries.append(.array(indexes))
        return index
    }

    mutating func appendDictionary(keys: [Int], values: [Int]) -> Int {
        let index = entries.count
        entries.append(.dictionary(keys: keys, values: values))
        return index
    }

    func finalize(rootIndex: Int) -> Data {
        let refSize = Self.byteWidth(for: max(entries.count - 1, 0))
        var result = Data("bplist00".utf8)
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(result.count)
            switch entry {
            case .scalar(let data):
                result.append(data)
            case .array(let indexes):
                result.append(Self.collectionHeader(type: 0xA0, count: indexes.count))
                for index in indexes {
                    result.append(Self.bigEndian(index, byteCount: refSize))
                }
            case .dictionary(let keys, let values):
                result.append(Self.collectionHeader(type: 0xD0, count: keys.count))
                for key in keys {
                    result.append(Self.bigEndian(key, byteCount: refSize))
                }
                for value in values {
                    result.append(Self.bigEndian(value, byteCount: refSize))
                }
            }
        }

        let offsetTableOffset = result.count
        let offsetSize = Self.byteWidth(for: offsetTableOffset)
        for offset in offsets {
            result.append(Self.bigEndian(offset, byteCount: offsetSize))
        }

        result.append(Data(count: 6))
        result.append(UInt8(offsetSize))
        result.append(UInt8(refSize))
        result.append(Self.bigEndian(entries.count, byteCount: 8))
        result.append(Self.bigEndian(rootIndex, byteCount: 8))
        result.append(Self.bigEndian(offsetTableOffset, byteCount: 8))

        return result
    }

    private mutating func appendScalar(_ data: Data) -> Int {
        let index = entries.count
        entries.append(.scalar(data))
        return index
    }

    private static func encode(string: String) -> Data {
        if string.allSatisfy(\.isASCII) {
            var data = collectionHeader(type: 0x50, count: string.utf8.count)
            data.append(contentsOf: string.utf8)
            return data
        }

        let utf16 = Array(string.utf16)
        var data = collectionHeader(type: 0x60, count: utf16.count)
        for codeUnit in utf16 {
            data.append(UInt8((codeUnit >> 8) & 0xFF))
            data.append(UInt8(codeUnit & 0xFF))
        }
        return data
    }

    private static func encode(integer: Int) -> Data {
        if integer <= 0xFF {
            return Data([0x10]) + bigEndian(integer, byteCount: 1)
        }
        if integer <= 0xFFFF {
            return Data([0x11]) + bigEndian(integer, byteCount: 2)
        }
        if integer <= 0xFFFF_FFFF {
            return Data([0x12]) + bigEndian(integer, byteCount: 4)
        }
        return Data([0x13]) + bigEndian(integer, byteCount: 8)
    }

    private static func encode(data: Data) -> Data {
        var encoded = collectionHeader(type: 0x40, count: data.count)
        encoded.append(data)
        return encoded
    }

    private static func encode(uid: Int) -> Data {
        let width = byteWidth(for: uid)
        return Data([0x80 | UInt8(width - 1)]) + bigEndian(uid, byteCount: width)
    }

    private static func collectionHeader(type: UInt8, count: Int) -> Data {
        guard count >= 15 else {
            return Data([type | UInt8(count)])
        }

        var data = Data([type | 0x0F])
        data.append(encode(integer: count))
        return data
    }

    private static func byteWidth(for value: Int) -> Int {
        if value <= 0xFF { return 1 }
        if value <= 0xFFFF { return 2 }
        if value <= 0xFFFF_FFFF { return 4 }
        return 8
    }

    private static func bigEndian(_ value: Int, byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        for index in 0..<byteCount {
            let shift = (byteCount - index - 1) * 8
            data[index] = UInt8((value >> shift) & 0xFF)
        }
        return data
    }
}
