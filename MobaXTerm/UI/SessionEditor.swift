import SwiftUI

struct SessionEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var customBaud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("名称", text: $model.editorDraft.name)
                    .accessibilityIdentifier("session.name")
                Picker("类型", selection: $model.editorDraft.kind) {
                    ForEach(SessionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .accessibilityIdentifier("session.kind")
                .onChange(of: model.editorDraft.kind) { _, _ in
                    model.ensureEditorSettings()
                }
                switch model.editorDraft.kind {
                case .ssh:
                    sshFields
                case .serial:
                    serialFields
                case .local:
                    localFields
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error = model.editorError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("取消") { model.isPresentingEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("session.save")
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            model.ensureEditorSettings()
            let baud = model.editorDraft.serial?.baudRate ?? 115200
            customBaud = !SerialSettings.baudPresets.contains(baud)
        }
    }

    private var sshFields: some View {
        Group {
            TextField("主机", text: sshBinding(\.host))
                .accessibilityIdentifier("session.host")
            TextField("端口", value: sshPort, format: .number)
            TextField("用户名", text: sshBinding(\.username))
            HStack {
                TextField("私钥", text: sshBinding(\.identityFile))
                Button("选择…") { model.chooseIdentityFile() }
            }
            TextField("附加参数", text: sshBinding(\.extraArguments))
            TextField("远程命令", text: sshBinding(\.remoteCommand))
            Text("使用系统 OpenSSH，会读取 ~/.ssh/config 和 SSH agent。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serialFields: some View {
        Group {
            Picker("选择端口", selection: serialBinding(\.devicePath)) {
                Text("未选择").tag("")
                ForEach(model.livePorts) { device in
                    Text("\(device.name) (\(device.path))").tag(device.path)
                }
            }
            TextField("设备路径", text: serialBinding(\.devicePath))
                .accessibilityIdentifier("session.path")
            Picker("波特率", selection: baudSelection) {
                ForEach(SerialSettings.baudPresets, id: \.self) { rate in
                    Text("\(rate)").tag(rate)
                }
                Text("自定义").tag(0)
            }
            if customBaud {
                TextField("自定义波特率", value: serialBinding(\.baudRate), format: .number)
            }
            Picker("数据位", selection: serialBinding(\.dataBits)) {
                ForEach([5, 6, 7, 8], id: \.self) { bits in
                    Text("\(bits)").tag(bits)
                }
            }
            Picker("校验", selection: serialBinding(\.parity)) {
                ForEach(Parity.allCases) { parity in
                    Text(parity.title).tag(parity)
                }
            }
            Picker("停止位", selection: serialBinding(\.stopBits)) {
                Text("1").tag(1)
                Text("2").tag(2)
            }
            Picker("流控", selection: serialBinding(\.flowControl)) {
                ForEach(FlowControl.allCases) { flow in
                    Text(flow.title).tag(flow)
                }
            }
            Toggle("本地回显", isOn: serialBinding(\.localEcho))
            Picker("发送换行", selection: serialBinding(\.newline)) {
                ForEach(NewlineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    private var localFields: some View {
        Group {
            TextField("可执行文件", text: localBinding(\.executable), prompt: Text("默认 $SHELL"))
            TextField("参数", text: localBinding(\.arguments))
        }
    }

    private var baudSelection: Binding<Int> {
        Binding(
            get: {
                customBaud ? 0 : (model.editorDraft.serial?.baudRate ?? 115200)
            },
            set: { newValue in
                if newValue == 0 {
                    customBaud = true
                } else {
                    customBaud = false
                    model.editorDraft.serial?.baudRate = newValue
                }
            }
        )
    }

    private var sshPort: Binding<Int> {
        Binding(
            get: { model.editorDraft.ssh?.port ?? 22 },
            set: { model.editorDraft.ssh?.port = $0 }
        )
    }

    private func sshBinding(_ keyPath: WritableKeyPath<SSHSettings, String>) -> Binding<String> {
        Binding(
            get: { model.editorDraft.ssh?[keyPath: keyPath] ?? "" },
            set: { model.editorDraft.ssh?[keyPath: keyPath] = $0 }
        )
    }

    private func serialBinding<Value>(_ keyPath: WritableKeyPath<SerialSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.editorDraft.serial?[keyPath: keyPath] ?? SerialSettings()[keyPath: keyPath] },
            set: { model.editorDraft.serial?[keyPath: keyPath] = $0 }
        )
    }

    private func localBinding(_ keyPath: WritableKeyPath<LocalSettings, String>) -> Binding<String> {
        Binding(
            get: { model.editorDraft.local?[keyPath: keyPath] ?? "" },
            set: { model.editorDraft.local?[keyPath: keyPath] = $0 }
        )
    }
}
