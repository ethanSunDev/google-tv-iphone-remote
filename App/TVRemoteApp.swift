import AndroidTVRemoteControl
import AVFoundation
import SwiftUI

@main
@MainActor
struct TVRemoteApp: App {
    var body: some Scene {
        WindowGroup { RemoteView() }
    }
}

@MainActor
private struct RemoteView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = TVRemoteModel()
    @FocusState private var focused: Field?
    @State private var keyboardShown = false
    @State private var microphoneHeld = false

    private let accent = Color(red: 0.36, green: 0.88, blue: 0.76)
    private let surface = Color(red: 0.11, green: 0.15, blue: 0.19)

    private enum Field { case host, code }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    connection
                    controls
                        .disabled(model.phase != .ready)
                        .opacity(model.phase == .ready ? 1 : 0.44)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .background {
                RadialGradient(colors: [Color(red: 0.10, green: 0.20, blue: 0.23),
                                        Color(red: 0.05, green: 0.07, blue: 0.10)],
                               center: .topTrailing, startRadius: 12, endRadius: 540)
                    .ignoresSafeArea()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("电视遥控器")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $keyboardShown) {
            TVKeyboardSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { model.resume() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.resume() }
            if phase == .background { model.stop() }
        }
        .onChange(of: model.phase) { phase in
            if phase != .ready { microphoneHeld = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if model.voiceActive, type == AVAudioSession.InterruptionType.began.rawValue {
                model.finishVoice(message: "麦克风录音已中断。")
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "tv")
                    .font(.headline)
                    .foregroundStyle(accent)
                Text("Google TV").font(.headline)
                Spacer()
                Circle()
                    .fill(model.phase == .ready ? accent : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.phase == .idle {
                TextField("电视 IP，例如 192.168.1.20", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($focused, equals: .host)
                    .onSubmit(connect)
                HStack {
                    Button("连接", action: connect).buttonStyle(.borderedProminent)
                    Button("重新配对") {
                        focused = nil
                        model.pair()
                    }.buttonStyle(.bordered)
                }
                .disabled(!model.canConnect)
            } else if model.phase == .code {
                TextField("例如 A1B2C3", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($focused, equals: .code)
                    .onSubmit(submitCode)
                HStack {
                    Button("确认配对", action: submitCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSubmit)
                    Button("取消") { model.stop() }.buttonStyle(.bordered)
                }
            } else {
                HStack {
                    if model.phase != .ready { ProgressView() }
                    Button(model.phase == .ready ? "断开" : "取消") { model.stop() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)) }
    }

    private var controls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                inputButton("键盘", icon: "keyboard", enabled: model.textSupported) { keyboardShown = true }
                voiceButton
            }
            if let message = model.voiceStatus {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(model.voiceActive ? accent : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 7) {
                direction(.KEYCODE_DPAD_UP, "chevron.up", "上")
                HStack(spacing: 7) {
                    direction(.KEYCODE_DPAD_LEFT, "chevron.left", "左")
                    direction(.KEYCODE_DPAD_CENTER, "circle.inset.filled", "确定", center: true)
                    direction(.KEYCODE_DPAD_RIGHT, "chevron.right", "右")
                }
                direction(.KEYCODE_DPAD_DOWN, "chevron.down", "下")
            }
            .padding(12)
            .background {
                Circle().fill(surface)
                    .overlay { Circle().strokeBorder(.white.opacity(0.11)) }
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 7)
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                remoteButton(.KEYCODE_BACK, "arrow.uturn.backward", "返回")
                remoteButton(.KEYCODE_HOME, "house.fill", "主页")
                remoteButton(.KEYCODE_MEDIA_PLAY_PAUSE, "playpause.fill", "播放或暂停")
                remoteButton(.KEYCODE_POWER, "power", "电源", tint: .orange)
            }
            HStack(spacing: 10) {
                remoteButton(.KEYCODE_VOLUME_DOWN, "speaker.wave.1.fill", "降低音量")
                remoteButton(.KEYCODE_VOLUME_MUTE, "speaker.slash.fill", "静音")
                remoteButton(.KEYCODE_VOLUME_UP, "speaker.wave.3.fill", "提高音量")
            }
        }
    }

    private func inputButton(_ label: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 51)
                .background(surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(RemotePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var voiceButton: some View {
        Label(model.voiceActive ? "录音中" : "按住说话", systemImage: model.voiceActive ? "waveform" : "mic.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(model.voiceActive ? Color.black : accent)
            .frame(maxWidth: .infinity, minHeight: 51)
            .background(model.voiceActive ? accent : accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !microphoneHeld, model.phase == .ready, model.voiceSupported else { return }
                    microphoneHeld = true
                    model.startVoice()
                }
                .onEnded { _ in
                    microphoneHeld = false
                    if model.voiceActive { model.finishVoice() }
                })
            .opacity(model.voiceSupported ? 1 : 0.45)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.voiceActive ? "结束语音" : "开始语音")
            .accessibilityHint(model.voiceSupported ? "" : "当前电视未提供语音搜索")
            .accessibilityAction {
                if model.voiceActive { model.finishVoice() } else { model.startVoice() }
            }
    }

    private func direction(_ key: Key, _ icon: String, _ title: String, center: Bool = false) -> some View {
        Button { model.send(key) } label: {
            Group {
                if center { Text("OK").font(.system(.headline, design: .rounded).weight(.heavy)) }
                else { Image(systemName: icon).font(.title3.weight(.bold)) }
            }
            .frame(width: 56, height: 56)
            .foregroundStyle(center ? Color.black : Color.white)
            .background(center ? accent : .white.opacity(0.06), in: Circle())
        }
        .buttonStyle(RemotePressStyle())
        .accessibilityLabel(title)
    }

    private func remoteButton(_ key: Key, _ icon: String, _ title: String, tint: Color = .white) -> some View {
        Button { model.send(key) } label: {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(tint)
                .background(surface, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(RemotePressStyle())
        .accessibilityLabel(title)
    }

    private func connect() {
        focused = nil
        model.connect()
    }

    private func submitCode() {
        focused = nil
        model.submitCode()
    }
}

private struct RemotePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
private struct TVKeyboardSheet: View {
    @ObservedObject var model: TVRemoteModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.textFocused ? "输入或粘贴文字，再发送到电视。" : "先在电视上选中搜索框或其他输入框。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("输入文字", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .focused($typing)
                Button {
                    if model.sendText(text) { text = "" }
                } label: {
                    Label("发送到电视", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.textFocused || text.isEmpty || text.utf8.count > 16_384)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("电视键盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task { typing = true }
    }
}
