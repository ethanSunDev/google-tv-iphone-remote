import Foundation
import Network
import Security

@MainActor
final class TVRemoteChannel {
    enum Event {
        case ready(text: Bool, voice: Bool)
        case textFocus(Bool)
        case voiceBegin(UInt64)
        case voiceEnd(UInt64)
        case failed(String)
    }

    private struct Editor {
        var id: UInt64
        var counter: UInt64
        var start: UInt64
        var end: UInt64
    }

    private typealias Wire = TVRemoteWire
    private static let ime: UInt64 = 4
    private static let voice: UInt64 = 8
    private static let wanted: UInt64 = 1 | 2 | ime | voice | 32 | 64
    private let connection: NWConnection
    private let event: (Event) -> Void
    private var buffer = Data()
    private var features: UInt64?
    private var active = false
    private var closed = false
    private var editor: Editor?

    init?(host: String, identity: SecIdentity, expectedKey: Data, event: @escaping (Event) -> Void) {
        guard let local = sec_identity_create(identity) else { return nil }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, verify in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let key = SecTrustCopyKey(trust), let data = SecKeyCopyExternalRepresentation(key, nil) else {
                verify(false)
                return
            }
            verify((data as Data) == expectedKey)
        }, .main)
        connection = NWConnection(host: NWEndpoint.Host(host), port: 6466,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.event = event
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.receive()
                case .waiting(let error), .failed(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    func close() {
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(_ message: Data) {
        guard !closed else { return }
        connection.send(content: Wire.frame(message), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.fail(error.localizedDescription) }
        })
    }

    func sendText(_ text: String) -> Bool {
        guard active, var editor, !text.isEmpty, text.utf8.count <= 16_384 else { return false }
        let replacement = Wire.integer(1, editor.start) + Wire.integer(2, editor.end) + Wire.string(3, text)
        let edit = Wire.integer(1, 1) + Wire.bytes(2, replacement)
        let batch = Wire.integer(1, editor.id) + Wire.integer(2, editor.counter) + Wire.bytes(3, edit)
        send(Wire.bytes(21, batch))
        if editor.id != 0 {
            editor.start += UInt64(text.utf16.count)
            editor.end = editor.start
            self.editor = editor
        }
        return true
    }

    func sendVoice(_ field: UInt64, session: UInt64, audio: Data? = nil) {
        var message = Wire.integer(1, session)
        if let audio { message += Wire.bytes(2, audio) }
        send(Wire.bytes(field, message))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                do {
                    if let data {
                        self.buffer.append(data)
                        while !self.closed, let frame = try Wire.popFrame(from: &self.buffer) {
                            try self.handle(Wire.Message(frame))
                        }
                    }
                    if let error { self.fail(error.localizedDescription) }
                    else if done { self.fail("电视已关闭连接。") }
                    else if !self.closed { self.receive() }
                } catch {
                    self.fail("无法读取电视的遥控消息。")
                }
            }
        }
    }

    private func handle(_ message: Wire.Message) throws {
        if let configure = try message.nested(1) {
            let negotiated = (configure.integer(1) ?? 0) & Self.wanted
            guard negotiated & 2 != 0 else { fail("电视未开启网络遥控。") ; return }
            features = negotiated
            let info = Wire.string(1, "iPhone") + Wire.string(2, "Apple") + Wire.integer(3, 2)
                + Wire.string(4, ProcessInfo.processInfo.operatingSystemVersionString)
                + Wire.string(5, "ca.ethansun.tvremote") + Wire.string(6, "1.2")
            send(Wire.bytes(1, Wire.integer(1, negotiated) + Wire.bytes(2, info)))
        } else if message.bytes(2) != nil, let features {
            send(Wire.bytes(2, Wire.integer(1, features)))
            if !active {
                active = true
                event(.ready(text: features & Self.ime != 0, voice: features & Self.voice != 0))
            }
        } else if let ping = try message.nested(8) {
            send(Wire.bytes(9, Wire.integer(1, ping.integer(1) ?? 0)))
        } else if let focus = try message.nested(20) {
            let info = try focus.nested(1)
            let status = try focus.nested(2)
            let id = info?.integer(1) ?? 0
            if (info?.integer(2) ?? 0) != 0 || status != nil {
                editor = Editor(id: id, counter: 0, start: 0, end: 0)
                if let status { updateEditor(status) }
            } else {
                editor = nil
            }
            event(.textFocus(editor != nil))
        } else if let change = try message.nested(22), let status = try change.nested(2), editor != nil {
            updateEditor(status)
        } else if let selection = try message.nested(23), var editor {
            editor.start = min(selection.integer(2) ?? 0, 1_000_000)
            editor.end = max(editor.start, min(selection.integer(3) ?? 0, 1_000_000))
            self.editor = editor
        } else if let begin = try message.nested(30), let id = begin.integer(1) {
            event(.voiceBegin(id))
        } else if let end = try message.nested(32), let id = end.integer(1) {
            event(.voiceEnd(id))
        } else if message.bytes(3) != nil {
            fail("电视拒绝了遥控指令。")
        }
    }

    private func updateEditor(_ status: Wire.Message) {
        guard var editor else { return }
        editor.counter = status.integer(1) ?? 0
        let text = status.bytes(2).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let limit = UInt64(text.utf16.count)
        editor.start = min(status.integer(3) ?? 0, limit)
        editor.end = max(editor.start, min(status.integer(4) ?? 0, limit))
        self.editor = editor
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        close()
        event(.failed(message))
    }
}
