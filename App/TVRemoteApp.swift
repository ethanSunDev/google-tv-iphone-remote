import AndroidTVRemoteControl
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

    private enum Field { case host, code }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    connection
                    controls
                        .disabled(model.phase != .ready)
                        .opacity(model.phase == .ready ? 1 : 0.45)
                }
                .frame(maxWidth: 420)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("电视遥控器")
        }
        .onAppear { model.resume() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.resume() }
            if phase == .background { model.stop() }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google TV").font(.headline)
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            remoteButton(.KEYCODE_DPAD_UP, "chevron.up", "上")
                .frame(maxWidth: 108)
            HStack(spacing: 10) {
                remoteButton(.KEYCODE_DPAD_LEFT, "chevron.left", "左")
                remoteButton(.KEYCODE_DPAD_CENTER, "circle.inset.filled", "确定", primary: true)
                remoteButton(.KEYCODE_DPAD_RIGHT, "chevron.right", "右")
            }
            remoteButton(.KEYCODE_DPAD_DOWN, "chevron.down", "下")
                .frame(maxWidth: 108)
            HStack(spacing: 10) {
                remoteButton(.KEYCODE_BACK, "arrow.uturn.backward", "返回")
                remoteButton(.KEYCODE_HOME, "house.fill", "主页")
                remoteButton(.KEYCODE_MEDIA_PLAY_PAUSE, "playpause.fill", "播放或暂停")
            }
            .padding(.top, 12)
            HStack(spacing: 10) {
                remoteButton(.KEYCODE_VOLUME_DOWN, "speaker.wave.1.fill", "降低音量")
                remoteButton(.KEYCODE_VOLUME_MUTE, "speaker.slash.fill", "静音")
                remoteButton(.KEYCODE_VOLUME_UP, "speaker.wave.3.fill", "提高音量")
            }
            remoteButton(.KEYCODE_POWER, "power", "电源")
                .frame(maxWidth: 108)
        }
    }

    private func remoteButton(_ key: Key, _ icon: String, _ title: String, primary: Bool = false) -> some View {
        Button { model.send(key) } label: {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 57)
                .foregroundStyle(primary ? Color.white : Color.primary)
                .background(primary ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
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
