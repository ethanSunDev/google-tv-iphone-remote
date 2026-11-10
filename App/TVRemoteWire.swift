import Foundation

// The TV sends length-prefixed protobuf messages over a TCP byte stream.
enum TVRemoteWire {
    enum Invalid: Error { case frame, field }

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        while value >= 128 {
            result.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }

    static func integer(_ field: UInt64, _ value: UInt64) -> Data {
        varint(field << 3) + varint(value)
    }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        varint((field << 3) | 2) + varint(UInt64(value.count)) + value
    }

    static func string(_ field: UInt64, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    static func frame(_ message: Data) -> Data {
        varint(UInt64(message.count)) + message
    }

    static func popFrame(from buffer: inout Data) throws -> Data? {
        var cursor = buffer.startIndex
        guard let length = try readVarint(buffer, cursor: &cursor) else { return nil }
        guard length <= 1_048_576 else { throw Invalid.frame }
        let end = cursor + Int(length)
        guard end <= buffer.endIndex else { return nil }
        let message = Data(buffer[cursor..<end])
        buffer.removeFirst(end - buffer.startIndex)
        return message
    }

    private static func readVarint(_ data: Data, cursor: inout Data.Index) throws -> UInt64? {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard cursor < data.endIndex else { return nil }
            let byte = data[cursor]
            cursor += 1
            guard shift != 63 || byte <= 1 else { throw Invalid.field }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
        }
        throw Invalid.field
    }

    struct Message {
        private var integers: [UInt64: UInt64] = [:]
        private var blobs: [UInt64: Data] = [:]

        init(_ data: Data) throws {
            var cursor = data.startIndex
            while cursor < data.endIndex {
                guard let tag = try readVarint(data, cursor: &cursor), tag >> 3 != 0 else { throw Invalid.field }
                let field = tag >> 3
                switch tag & 7 {
                case 0:
                    guard let value = try readVarint(data, cursor: &cursor) else { throw Invalid.field }
                    integers[field] = value
                case 2:
                    guard let rawCount = try readVarint(data, cursor: &cursor), let count = Int(exactly: rawCount),
                          count <= data.endIndex - cursor else {
                        throw Invalid.field
                    }
                    let end = cursor + count
                    blobs[field] = Data(data[cursor..<end])
                    cursor = end
                case 1, 5:
                    let count = (tag & 7 == 1) ? 8 : 4
                    guard count <= data.endIndex - cursor else { throw Invalid.field }
                    cursor += count
                default:
                    throw Invalid.field
                }
            }
        }

        func integer(_ field: UInt64) -> UInt64? { integers[field] }
        func bytes(_ field: UInt64) -> Data? { blobs[field] }
        func nested(_ field: UInt64) throws -> Message? { try blobs[field].map(Message.init) }
    }
}
