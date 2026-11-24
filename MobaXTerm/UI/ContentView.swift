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
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.tabs.isEmpty {
                        welcome
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
