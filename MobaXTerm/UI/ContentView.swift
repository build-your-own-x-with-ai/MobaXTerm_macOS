import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                TerminalTabBar()
                ZStack(alignment: .bottom) {
                    TerminalHostView(
                        controllers: model.visibleControllers,
                        selectedID: model.selectedTabID
                    ) { urls in
                        model.sendDroppedFiles(urls)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.tabs.isEmpty {
                        welcome
                    }
                    if let progress = model.selectedTab?.transfer {
                        TransferBar(progress: progress)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    if let tab = model.selectedTab, tab.ended {
                        endedBanner(tab)
                    }
                }
                Divider()
                StatusBar()
            }
        }
        .navigationTitle("MobaXTerm")
        .sheet(isPresented: $model.isPresentingEditor) {
            SessionEditor()
                .environmentObject(model)
        }
        .alert("提示", isPresented: alertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear { model.start() }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("打开会话、串口或本地终端")
                .font(.title3)
            HStack(spacing: 12) {
                Button("新建会话") { model.beginNewSession() }
                Button("本地终端") { model.openLocalTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func endedBanner(_ tab: TerminalTab) -> some View {
        HStack(spacing: 12) {
            Text(tab.endMessage ?? "会话已结束")
                .accessibilityIdentifier("session.ended")
                .accessibilityLabel(tab.endMessage ?? "会话已结束")
            Button("重新连接") { model.reconnectSelected() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }
}

private struct TransferBar: View {
    var progress: ZmodemProgress

    private var fraction: Double {
        guard progress.total > 0 else { return 1 }
        return min(1, Double(progress.sent) / Double(progress.total))
    }

    private var percent: Int {
        Int((fraction * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(progress.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(progress.phase == .sending ? "\(percent)%" : "等待应答")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.35))
            }
            if progress.phase == .sending {
                ProgressView(value: fraction)
                    .tint(Color(red: 0.95, green: 0.78, blue: 0.35))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack {
                Text(progress.phase == .sending ? "\(formatBytes(progress.sent)) / \(formatBytes(progress.total))" : "正在联系远端")
                Spacer()
                if progress.fileCount > 1 {
                    Text("\(progress.fileIndex)/\(progress.fileCount)")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer.progress")
        .accessibilityLabel("\(title) \(progress.name) \(progress.phase == .sending ? "\(percent)%" : "等待应答")")
    }

    private var title: String {
        switch progress.phase {
        case .launching: return "正在启动 rz"
        case .waiting: return "等待 rz"
        case .sending: return "正在发送"
        }
    }

    private func formatBytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        let kilobytes = Double(count) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.selectedTab?.statusText ?? "未连接")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .accessibilityIdentifier("session.status")
                .accessibilityLabel(model.selectedTab?.statusText ?? "未连接")
            Spacer()
            if let tab = model.selectedTab, tab.kind == .serial, !tab.ended {
                Toggle("DTR", isOn: Binding(
                    get: { tab.dtr },
                    set: { model.setDTR($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                Toggle("RTS", isOn: Binding(
                    get: { tab.rts },
                    set: { model.setRTS($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
