import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            ForEach(SessionKind.allCases) { kind in
                Section(kind.title) {
                    let saved = model.sessions.filter { $0.kind == kind }
                    if saved.isEmpty {
                        Text("无会话")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(saved) { session in
                        sessionRow(session)
                            .tag(SidebarSelection.session(session.id))
                    }
                }
            }
            Section("当前串口") {
                if model.livePorts.isEmpty {
                    Text("未发现串口")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.livePorts) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(SidebarSelection.port(device.path))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        DispatchQueue.main.async { model.openPort(device) }
                    }
                    .contextMenu {
                        Button("连接") { model.openPort(device) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            model.openSidebarSelection()
            return .handled
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshPorts()
                } label: {
                    Label("刷新串口", systemImage: "arrow.clockwise")
                }
                Button {
                    model.beginNewSession()
                } label: {
                    Label("新建会话", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.openLocalTerminal()
            } label: {
                Label("本地终端", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("open.local")
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        Label(session.name, systemImage: session.kind.symbolName)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                DispatchQueue.main.async { model.open(session) }
            }
            .contextMenu {
                Button("连接") { model.open(session) }
                Button("编辑") { model.beginEditing(session) }
                Divider()
                Button("删除", role: .destructive) { model.deleteSession(session.id) }
            }
    }
}
