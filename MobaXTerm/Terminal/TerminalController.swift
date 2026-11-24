import AppKit
import Foundation
import SwiftTerm

@MainActor
final class TerminalController: NSObject {
    let id: UUID
    let kind: SessionKind
    private(set) var view: NSView

    var onTitle: ((String) -> Void)?
    var onEnded: ((String) -> Void)?
    var onModem: ((Bool, Bool) -> Void)?
    var onViewReplaced: (() -> Void)?

    private let launch: Launch
    private var processView: LocalProcessTerminalView?
    private var serialTerminal: TerminalView?
    private var serialPort: SerialPort?
    private var serialSettings: SerialSettings?
    private var started = false
    private var acceptEnd = true
    private var reportedEnd = false
    private var generation = 0
    private var serialGate = true
    private let processBridge = ProcessBridge()
    private let serialBridge = SerialBridge()

    private enum Launch {
        case process(executable: String, arguments: [String], directory: String)
        case serial(SerialSettings)
    }

    init(id: UUID, session: Session) {
        self.id = id
        self.kind = session.kind
        self.view = NSView()
        switch session.kind {
        case .ssh:
            let settings = session.ssh ?? SSHSettings()
            launch = .process(
                executable: "/usr/bin/ssh",
                arguments: SSHCommand.arguments(for: settings),
                directory: SSHCommand.homeDirectory()
            )
        case .local:
            let settings = session.local ?? LocalSettings()
            launch = .process(
                executable: settings.resolvedExecutable,
                arguments: settings.resolvedArguments,
                directory: SSHCommand.homeDirectory()
            )
        case .serial:
            launch = .serial(session.serial ?? SerialSettings())
        }
        super.init()
        processBridge.owner = self
        serialBridge.owner = self
        buildView()
    }

    func ensureStarted() {
        guard !started, serialGate else { return }
        guard view.bounds.width > 2, view.bounds.height > 2 else { return }
        started = true
        generation += 1
        let token = generation
        switch launch {
        case let .process(executable, arguments, directory):
            processView?.startProcess(
                executable: executable,
                args: arguments,
                environment: SSHCommand.childEnvironment(),
                currentDirectory: directory
            )
        case let .serial(settings):
            openSerial(settings, token: token)
        }
    }

    func reconnect() {
        acceptEnd = false
        generation += 1
        let oldPort = serialPort
        serialPort = nil
        releaseProcess()
        serialTerminal?.terminalDelegate = nil
        serialTerminal = nil
        reportedEnd = false
        started = false
        acceptEnd = true
        buildView()
        onViewReplaced?()
        guard let oldPort else { return }
        serialGate = false
        oldPort.close { [weak self] in
            self?.serialGate = true
            self?.ensureStarted()
        }
    }

    func stop() {
        acceptEnd = false
        generation += 1
        stopResources()
    }

    func setDTR(_ enabled: Bool) {
        serialPort?.setDataTerminalReady(enabled)
        publishModem()
    }

    func setRTS(_ enabled: Bool) {
        serialPort?.setRequestToSend(enabled)
        publishModem()
    }

    private func buildView() {
        switch launch {
        case .process:
            let terminal = LocalProcessTerminalView(frame: .zero)
            applyTheme(terminal)
            terminal.processDelegate = processBridge
            processView = terminal
            serialTerminal = nil
            serialPort = nil
            view = terminal
        case let .serial(settings):
            let terminal = TerminalView(frame: .zero)
            applyTheme(terminal)
            terminal.terminalDelegate = serialBridge
            serialTerminal = terminal
            serialSettings = settings
            processView = nil
            view = terminal
        }
    }

    private func applyTheme(_ terminal: TerminalView) {
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        terminal.caretColor = NSColor(srgbRed: 0.95, green: 0.78, blue: 0.35, alpha: 1)
    }

    private func stopResources() {
        releaseProcess()
        serialTerminal?.terminalDelegate = nil
        serialTerminal = nil
        serialPort?.close()
        serialPort = nil
    }

    private func releaseProcess() {
        processView?.processDelegate = nil
        processView?.terminate()
        processView = nil
    }

    private func openSerial(_ settings: SerialSettings, token: Int) {
        let port = SerialPort()
        let terminal = serialTerminal
        port.onData = { bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        port.onDisconnect = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.reportEnd(message)
            }
        }
        serialPort = port
        do {
            try port.open(path: settings.devicePath, settings: settings)
            publishModem()
        } catch {
            reportEnd(error.localizedDescription)
        }
    }

    private func publishModem() {
        guard let lines = serialPort?.modemLines() else { return }
        onModem?(lines.dtr, lines.rts)
    }

    private func reportEnd(_ message: String) {
        guard acceptEnd, !reportedEnd else { return }
        reportedEnd = true
        let terminal = serialTerminal ?? processView
        terminal?.feed(text: "\r\n\r\n[\(message)]\r\n")
        onEnded?(message)
    }

    private func describe(_ error: LocalProcessError) -> String {
        switch error {
        case .alreadyRunning:
            return "进程仍在运行"
        case .notRunning:
            return "进程未运行"
        case let .forkFailed(code):
            return "无法创建进程（\(code)）"
        case let .writeChannelFailed(code):
            return "无法建立输入通道（\(code)）"
        case let .writeFailed(code, _):
            return "写入失败（\(code)）"
        }
    }

    fileprivate func noteTitle(_ title: String) {
        guard !title.isEmpty else { return }
        onTitle?(title)
    }

    fileprivate func noteProcessEnded(exitCode: Int32?) {
        if let exitCode {
            reportEnd("会话已结束（退出码 \(exitCode)）")
        } else {
            reportEnd("会话已结束")
        }
    }

    fileprivate func noteProcessFailed(_ error: LocalProcessError) {
        reportEnd("无法启动进程：\(describe(error))")
    }

    fileprivate func sendSerial(_ data: ArraySlice<UInt8>, source: TerminalView) {
        guard let settings = serialSettings else { return }
        let translated = translateOutgoing(Array(data), newline: settings.newline)
        serialPort?.write(translated)
        guard settings.localEcho, !translated.isEmpty else { return }
        let echo = translated
        DispatchQueue.main.async {
            source.feed(byteArray: echo[...])
        }
    }
}

@MainActor
private final class ProcessBridge: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TerminalController?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.noteTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.noteProcessEnded(exitCode: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        owner?.noteProcessFailed(error)
    }
}

@MainActor
private final class SerialBridge: NSObject, TerminalViewDelegate {
    weak var owner: TerminalController?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {
        owner?.noteTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        owner?.sendSerial(data, source: source)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
