import Foundation

@main
struct RemoteWireChecks {
    static func main() throws {
        typealias Wire = TVRemoteWire
        let text = "电视 🔎"
        let edit = Wire.bytes(21, Wire.string(3, text))
        let voice = Wire.bytes(31, Wire.integer(1, 7) + Wire.bytes(2, Data(repeating: 42, count: 8_192)))
        let audioFrame = Wire.frame(voice)
        var received = Data(audioFrame.prefix(1))
        let partialPrefix = try Wire.popFrame(from: &received)
        precondition(partialPrefix == nil && received.count == 1)
        received.append(audioFrame.dropFirst().prefix(100))
        let partialBody = try Wire.popFrame(from: &received)
        precondition(partialBody == nil && received.count == 101)
        received.append(audioFrame.dropFirst(101))
        received.append(Wire.frame(edit))
        let first = try Wire.popFrame(from: &received)
        let second = try Wire.popFrame(from: &received)
        precondition(first == voice && second == edit && received.isEmpty)
        let decodedText = try Wire.Message(edit).nested(21)?.bytes(3)
        let decodedVoice = try Wire.Message(voice).nested(31)
        precondition(decodedText == Data(text.utf8))
        precondition(decodedVoice?.integer(1) == 7 && decodedVoice?.bytes(2)?.count == 8_192)
        var oversized = Wire.varint(1_048_577)
        do {
            _ = try Wire.popFrame(from: &oversized)
            preconditionFailure("Expected the oversized frame to be rejected")
        } catch Wire.Invalid.frame {
            // The receiver rejects the invalid frame before buffering its contents.
        }
    }
}
