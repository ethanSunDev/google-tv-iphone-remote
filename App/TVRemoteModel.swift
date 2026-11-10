import AndroidTVRemoteControl
import Foundation
import Security
import SwiftUI

@MainActor
final class TVRemoteModel: ObservableObject {
    enum Phase {
        case idle, pairing, code, connecting, ready
    }

    @Published var host = UserDefaults.standard.string(forKey: "lastTV") ?? ""
    @Published var code = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "输入电视的局域网 IP 地址。"
    @Published private(set) var textSupported = false
    @Published private(set) var textFocused = false
    @Published private(set) var voiceSupported = false
    @Published private(set) var voiceActive = false
    @Published private(set) var voiceStatus: String?

    private let defaults = UserDefaults.standard
    private var identity: TVIdentity?
    private var pairing: PairingManager?
    private var remote: TVRemoteChannel?
    private var attempt = UUID()
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var discovery: TVDiscovery?
    private let microphone = TVVoiceCapture()
    private var voiceRequest: UUID?
    private var voiceSession: UInt64?
    private var voiceTimeout: Task<Void, Never>?
    private var audio = Data()
    private let audioChunkSize = 8_192

    private var address: String { host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var pin: String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var pins: [String: Data] { defaults.dictionary(forKey: "tvPublicKeys") as? [String: Data] ?? [:] }

    var canConnect: Bool { phase == .idle && !address.isEmpty }
    var canSubmit: Bool {
        phase == .code && pin.utf8.count == 6 && pin.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0)
        }
    }

    func connect() {
        guard canConnect else { return }
        if let expected = pins[address] ?? savedTV?.key {
            let address = self.address
            startRemote(address, expected: expected, seconds: 5) { [weak self] in
                self?.stop("无法用已保存的配对连接该地址。请核对 IP，或选择重新配对。")
            }
        } else {
            pair()
        }
    }

    func pair() {
        guard canConnect else { return }
        let address = self.address
        do {
            let identity = try getIdentity()
            let peer = PeerKey()
            let tls = makeTLS(identity, peer: peer)
            let crypto = CryptoManager()
            crypto.clientPublicCertificate = { .Result(identity.publicKey) }
            crypto.serverPublicCertificate = {
                guard let key = peer.read() else { return .Error(.secTrustCopyKeyError) }
                return .Result(key)
            }
            let manager = PairingManager(tls, crypto)
            let token = attempt
            manager.stateChanged = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.attempt == token else { return }
                    switch state {
                    case .waitingCode:
                        self.phase = .code
                        self.status = "输入电视屏幕上的 6 位配对码。"
                        self.armTimeout(seconds: 90)
                    case .successPaired:
                        guard let key = peer.bytes() else {
                            self.stop("无法读取电视证书，请重新配对。")
                            return
                        }
                        self.remember(address, key: key)
                        self.connectSaved(address, key: key)
                    case .error(let error):
                        if case .wrongCode = error {
                            self.stop("配对码有误。请重新配对，并输入电视上新显示的配对码。")
                        } else {
                            self.stop("配对失败。请确认电视已开机、IP 正确，然后重新配对。\n\(error.localizedDescription)")
                        }
                    default:
                        break
                    }
                }
            }
            pairing = manager
            code = ""
            phase = .pairing
            status = "正在请求电视显示配对码…"
            armTimeout(seconds: 20)
            manager.connect(address, "iPhone TV Remote", "iPhone")
        } catch {
            stop(error.localizedDescription)
        }
    }

    func submitCode() {
        guard canSubmit, let pairing else { return }
        phase = .pairing
        status = "正在验证配对码…"
        armTimeout(seconds: 15)
        pairing.sendSecret(pin)
    }

    func send(_ key: Key) {
        guard phase == .ready else { return }
        remote?.send(KeyPress(key).data)
    }

    func sendText(_ text: String) -> Bool {
        guard phase == .ready, textSupported else { return false }
        return remote?.sendText(text) == true
    }

    func startVoice() {
        guard phase == .ready, voiceSupported, voiceRequest == nil else { return }
        let request = UUID()
        voiceRequest = request
        voiceActive = true
        voiceStatus = "等待电视语音搜索…"
        Task { [weak self] in
            let allowed = await TVVoiceCapture.requestPermission()
            guard let self, self.voiceRequest == request else { return }
            guard allowed else {
                self.finishVoice(message: "请在 iPhone 设置中允许访问麦克风。")
                return
            }
            self.send(.KEYCODE_SEARCH)
            self.armVoiceTimeout(seconds: 4, message: "电视未开启语音搜索，请检查电视的语音助手设置。")
        }
    }

    func finishVoice(message: String? = nil, notifyTV: Bool = true) {
        voiceRequest = nil
        voiceTimeout?.cancel()
        voiceTimeout = nil
        microphone.stop()
        if notifyTV, let id = voiceSession {
            if !audio.isEmpty {
                audio.append(Data(repeating: 0, count: audioChunkSize - audio.count))
                remote?.sendVoice(31, session: id, audio: audio)
            }
            remote?.sendVoice(32, session: id)
        }
        voiceSession = nil
        audio.removeAll()
        voiceActive = false
        voiceStatus = message
    }

    private func beginVoice(session id: UInt64) {
        guard let request = voiceRequest, voiceSession == nil else { return }
        voiceSession = id
        remote?.sendVoice(30, session: id)
        do {
            try microphone.start { [weak self] data in
                DispatchQueue.main.async {
                    guard let self, self.voiceRequest == request else { return }
                    self.appendVoice(data, session: id)
                }
            }
            voiceStatus = "正在听…松开结束"
            armVoiceTimeout(seconds: 25, message: nil)
        } catch {
            finishVoice(message: "无法启动 iPhone 麦克风。")
        }
    }

    private func appendVoice(_ data: Data, session: UInt64) {
        audio.append(data)
        while audio.count >= audioChunkSize {
            remote?.sendVoice(31, session: session, audio: Data(audio.prefix(audioChunkSize)))
            audio.removeFirst(audioChunkSize)
        }
    }

    private func armVoiceTimeout(seconds: UInt64, message: String?) {
        voiceTimeout?.cancel()
        voiceTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishVoice(message: message)
        }
    }

    func resume() {
        guard phase == .idle, let saved = savedTV else { return }
        connectSaved(saved.address, key: saved.key)
    }

    private func connectSaved(_ address: String, key: Data) {
        startRemote(address, expected: key, seconds: 5) { [weak self] in
            self?.discoverSavedTV(previousAddress: address, key: key)
        }
    }

    func stop(_ message: String = "已断开连接。") {
        clearConnection()
        discovery?.stop()
        discovery = nil
        retry?.cancel()
        retry = nil
        phase = .idle
        code = ""
        status = message
    }

    private var savedTV: (address: String, key: Data)? {
        guard let address = defaults.string(forKey: "lastTV"), let key = pins[address] else { return nil }
        return (address, key)
    }

    private func remember(_ address: String, key: Data) {
        var updated = pins
        updated[address] = key
        defaults.set(updated, forKey: "tvPublicKeys")
        defaults.set(address, forKey: "lastTV")
        host = address
    }

    private func clearConnection() {
        finishVoice(notifyTV: false)
        textSupported = false
        textFocused = false
        voiceSupported = false
        attempt = UUID()
        timeout?.cancel()
        timeout = nil
        pairing?.disconnect()
        remote?.close()
        pairing = nil
        remote = nil
    }

    private func discoverSavedTV(previousAddress: String, key: Data) {
        clearConnection()
        phase = .connecting
        status = "正在局域网内寻找已配对的电视…"
        let scan = TVDiscovery()
        discovery = scan
        scan.start { [weak self, weak scan] addresses in
            guard let self, let scan, self.discovery === scan else { return }
            self.discovery = nil
            let candidates = addresses.filter { $0 != previousAddress }
            self.tryDiscovered(candidates[...], key: key)
        }
    }

    private func tryDiscovered(_ addresses: ArraySlice<String>, key: Data) {
        guard let address = addresses.first else {
            retrySavedTV()
            return
        }
        startRemote(address, expected: key, seconds: 4) { [weak self] in
            self?.tryDiscovered(addresses.dropFirst(), key: key)
        }
    }

    private func retrySavedTV() {
        clearConnection()
        guard savedTV != nil else {
            stop("电视已断开。")
            return
        }
        phase = .connecting
        status = "等待已配对的电视上线，将自动重连…"
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.phase = .idle
            self.resume()
        }
    }

    private func remoteFailed(_ message: String, recover: (() -> Void)?) {
        if phase == .ready {
            retrySavedTV()
        } else if let recover {
            recover()
        } else {
            stop(message)
        }
    }

    private func startRemote(_ address: String, expected: Data, seconds: UInt64 = 20,
                             recover: (() -> Void)? = nil) {
        clearConnection()
        code = ""
        do {
            let token = attempt
            let identity = try getIdentity()
            let channel = TVRemoteChannel(host: address, identity: identity.identity, expectedKey: expected) { [weak self] event in
                guard let self, self.attempt == token else { return }
                switch event {
                case .ready(let text, let voice):
                    self.timeout?.cancel()
                    self.timeout = nil
                    self.remember(address, key: expected)
                    self.phase = .ready
                    self.textSupported = text
                    self.voiceSupported = voice
                    self.status = "已连接 · \(address)"
                case .textFocus(let focused): self.textFocused = focused
                case .voiceBegin(let id): self.beginVoice(session: id)
                case .voiceEnd(let id):
                    if self.voiceSession == id { self.finishVoice(notifyTV: false) }
                case .failed(let error):
                    self.remoteFailed("连接中断或失败。\n\(error)", recover: recover)
                }
            }
            guard let channel else {
                stop("无法加载 iPhone 的遥控配对证书。")
                return
            }
            remote = channel
            phase = .connecting
            status = "正在连接电视…"
            armTimeout(seconds: seconds) { model in
                model.remoteFailed("连接超时。请确认电视已开机并接入同一局域网。", recover: recover)
            }
            channel.start()
        } catch {
            stop(error.localizedDescription)
        }
    }

    private func armTimeout(seconds: UInt64, onTimeout: ((TVRemoteModel) -> Void)? = nil) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if let onTimeout {
                onTimeout(self)
            } else {
                self.stop("操作超时。请确认电视开机，且 iPhone 和电视接入同一局域网。")
            }
        }
    }

    private func getIdentity() throws -> TVIdentity {
        if let identity { return identity }
        let created = try TVIdentity.load()
        identity = created
        return created
    }

    private func makeTLS(_ identity: TVIdentity, peer: PeerKey) -> TLSManager {
        let items = [[kSecImportItemIdentity as String: identity.identity]] as CFArray
        let tls = TLSManager { .Result(items) }
        tls.secTrustClosure = { trust in peer.save(SecTrustCopyKey(trust)) }
        return tls
    }
}

private final class PeerKey {
    private let lock = NSLock()
    private var key: SecKey?

    func save(_ key: SecKey?) {
        lock.lock()
        defer { lock.unlock() }
        self.key = key
    }

    func read() -> SecKey? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func bytes() -> Data? {
        guard let key = read(), let data = SecKeyCopyExternalRepresentation(key, nil) else { return nil }
        return data as Data
    }
}
