import AppKit
import Foundation
import SwiftUI

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var sessionID: UUID?
    var kind: SessionKind
    var statusText: String
    var ended: Bool
    var endMessage: String?
    var dtr: Bool
    var rts: Bool
    var transfer: ZmodemProgress? = nil
}

enum SidebarSelection: Hashable {
    case session(UUID)
    case port(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    @Published var livePorts: [SerialDevice] = []
    @Published var sidebarSelection: SidebarSelection?
    @Published var isPresentingEditor = false
    @Published var editorDraft = Session.makeSSH()
    @Published var editorError: String?
    @Published var alertMessage: String?

    private let store: SessionStore
    private let portMonitor = SerialPortMonitor()
    private var controllers: [UUID: TerminalController] = [:]
    private var didStart = false

    init(store: SessionStore = SessionStore(fileURL: SessionStore.defaultURL)) {
        self.store = store
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var visibleControllers: [TerminalController] {
        tabs.compactMap { controllers[$0.id] }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        sessions = (try? store.load()) ?? []
        portMonitor.onChange = { [weak self] in
            Task { @MainActor in
                self?.refreshPorts()
            }
        }
        portMonitor.start()
        refreshPorts()
    }

    func refreshPorts() {
        livePorts = SerialPortMonitor.listPorts()
    }

    func open(_ session: Session) {
        let tabID = UUID()
        let controller = TerminalController(id: tabID, session: session)
        controller.onTitle = { [weak self] title in
            self?.updateTab(tabID) { $0.title = title }
        }
        controller.onEnded = { [weak self] message in
            self?.updateTab(tabID) {
                $0.ended = true
                $0.endMessage = message
            }
        }
        controller.onModem = { [weak self] dtr, rts in
            self?.updateTab(tabID) {
                $0.dtr = dtr
                $0.rts = rts
            }
        }
        controller.onViewReplaced = { [weak self] in
            self?.objectWillChange.send()
        }
        controller.onTransferProgress = { [weak self] progress in
            self?.updateTab(tabID) {
                $0.transfer = progress
            }
        }
        controller.onNotice = { [weak self] message in
            self?.alertMessage = message
        }
        controllers[tabID] = controller
        tabs.append(TerminalTab(
            id: tabID,
            title: session.name,
            sessionID: session.id,
            kind: session.kind,
            statusText: session.statusText,
            ended: false,
            endMessage: nil,
            dtr: true,
            rts: true
        ))
        selectedTabID = tabID
    }

    func openLocalTerminal() {
        open(Session.makeLocal())
    }

    func openPort(_ device: SerialDevice) {
        open(Session.makeSerial(path: device.path, name: device.name))
    }

    func openSidebarSelection() {
        switch sidebarSelection {
        case let .session(id):
            if let session = sessions.first(where: { $0.id == id }) {
                open(session)
            }
        case let .port(path):
            if let device = livePorts.first(where: { $0.path == path }) {
                openPort(device)
            }
        case nil:
            break
        }
    }

    func closeTab(_ id: UUID) {
        controllers[id]?.stop()
        controllers[id] = nil
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
        }
    }

    func closeSelectedTab() {
        guard let id = selectedTabID else { return }
        closeTab(id)
    }

    func reconnectSelected() {
        guard let id = selectedTabID else { return }
        updateTab(id) {
            $0.ended = false
            $0.endMessage = nil
        }
        controllers[id]?.reconnect()
    }

    func setDTR(_ enabled: Bool) {
        guard let id = selectedTabID else { return }
        updateTab(id) { $0.dtr = enabled }
        controllers[id]?.setDTR(enabled)
    }

    func setRTS(_ enabled: Bool) {
        guard let id = selectedTabID else { return }
        updateTab(id) { $0.rts = enabled }
        controllers[id]?.setRTS(enabled)
    }

    func sendDroppedFiles(_ urls: [URL]) {
        guard let id = selectedTabID,
              let tab = tabs.first(where: { $0.id == id }),
              tab.kind == .serial,
              !tab.ended else {
            alertMessage = "把文件拖到已连接的串口窗口"
            return
        }
        controllers[id]?.sendFiles(urls)
    }

    func beginNewSession(kind: SessionKind = .ssh) {
        switch kind {
        case .ssh:
            editorDraft = Session.makeSSH()
        case .serial:
            editorDraft = Session.makeSerial()
        case .local:
            editorDraft = Session.makeLocal()
        }
        editorError = nil
        isPresentingEditor = true
    }

    func beginEditing(_ session: Session) {
        editorDraft = session
        editorError = nil
        isPresentingEditor = true
    }

    func saveEditor() {
        var draft = editorDraft
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else {
            editorError = "请填写名称"
            return
        }
        switch draft.kind {
        case .ssh:
            guard var ssh = draft.ssh else { return }
            ssh.host = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
            ssh.username = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssh.host.isEmpty else {
                editorError = "请填写主机"
                return
            }
            guard (1...65535).contains(ssh.port) else {
                editorError = "端口无效"
                return
            }
            draft.ssh = ssh
        case .serial:
            guard var serial = draft.serial else { return }
            serial.devicePath = serial.devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serial.devicePath.isEmpty else {
                editorError = "请填写设备路径"
                return
            }
            guard serial.baudRate > 0 else {
                editorError = "波特率无效"
                return
            }
            draft.serial = serial
        case .local:
            if draft.local == nil {
                draft.local = LocalSettings()
            }
        }
        if let index = sessions.firstIndex(where: { $0.id == draft.id }) {
            sessions[index] = draft
        } else {
            sessions.append(draft)
        }
        persist()
        editorError = nil
        isPresentingEditor = false
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if case let .session(selected) = sidebarSelection, selected == id {
            sidebarSelection = nil
        }
        persist()
    }

    func ensureEditorSettings() {
        switch editorDraft.kind {
        case .ssh where editorDraft.ssh == nil:
            editorDraft.ssh = SSHSettings()
        case .serial where editorDraft.serial == nil:
            editorDraft.serial = SerialSettings()
        case .local where editorDraft.local == nil:
            editorDraft.local = LocalSettings()
        default:
            break
        }
    }

    func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        let sshDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshDirectory.path) {
            panel.directoryURL = sshDirectory
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.editorDraft.ssh?.identityFile = url.path
            }
        }
    }

    private func persist() {
        do {
            try store.save(sessions)
        } catch {
            alertMessage = "无法保存会话：\(error.localizedDescription)"
        }
    }

    private func updateTab(_ id: UUID, _ change: (inout TerminalTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}
