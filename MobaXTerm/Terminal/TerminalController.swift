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
    var onTransferProgress: ((ZmodemProgress?) -> Void)?
    var onNotice: ((String) -> Void)?

    private let launch: Launch
    private var processView: LocalProcessTerminalView?
    private var serialTerminal: TerminalView?
    private var serialPort: SerialPort?
    private var serialSettings: SerialSettings?
    private var transfer: ZmodemSender?
    private var transferTimer: DispatchWorkItem?
    private var launchedRemote = false
    private var rxTail: [UInt8] = []
    private var lastZrinitAt: Date?
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
        cancelTransfer()
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
        cancelTransfer()
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

    func sendFiles(_ urls: [URL]) {
        guard kind == .serial else {
            onNotice?("把文件拖到已连接的串口窗口")
            return
        }
        guard serialPort != nil, !reportedEnd else {
            onNotice?("串口还没有连上")
            return
        }
        guard transfer == nil else {
            onNotice?("正在发送文件")
            return
        }
        var files: [ZmodemFile] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                onNotice?("不能发送文件夹")
                return
            }
            do {
                let data = try Data(contentsOf: url)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modified = attributes?[.modificationDate] as? Date ?? Date()
                let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                files.append(ZmodemFile(
                    name: url.lastPathComponent.precomposedStringWithCanonicalMapping,
                    bytes: [UInt8](data),
                    modified: modified,
                    mode: mode
                ))
            } catch {
                onNotice?("无法读取 \(url.lastPathComponent)")
                return
            }
        }
        guard !files.isEmpty else { return }
        let sender = ZmodemSender(files: files)
        transfer = sender
        let names = files.map(\.name).joined(separator: "、")
        if rzIsWaiting {
            lastZrinitAt = nil
            serialTerminal?.feed(text: "\r\n[发送 \(names)]\r\n")
        } else {
            launchedRemote = true
            let command = translateOutgoing(Array("rz\r".utf8), newline: serialSettings?.newline ?? .raw)
            serialPort?.write(command)
            serialTerminal?.feed(text: "\r\n[启动 rz，发送 \(names)]\r\n")
        }
        applyTransfer(sender.start())
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
        port.onData = { [weak self] bytes in
            Task { @MainActor in
                self?.ingestSerial(bytes)
            }
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
        cancelTransfer()
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

    private func ingestSerial(_ bytes: [UInt8]) {
        guard let transfer else {
            rememberZrinit(bytes)
            serialTerminal?.feed(byteArray: bytes[...])
            return
        }
        if transfer.showsRemoteText {
            serialTerminal?.feed(byteArray: bytes[...])
        }
        applyTransfer(transfer.receive(bytes))
    }

    private var rzIsWaiting: Bool {
        guard let lastZrinitAt else { return false }
        return Date().timeIntervalSince(lastZrinitAt) < 15
    }

    private func rememberZrinit(_ bytes: [UInt8]) {
        rxTail.append(contentsOf: bytes)
        if rxTail.count > 96 {
            rxTail.removeFirst(rxTail.count - 96)
        }
        let marker: [UInt8] = [0x18, 0x42, 0x30, 0x31]
        guard rxTail.count >= marker.count else { return }
        for start in 0...(rxTail.count - marker.count) where Array(rxTail[start..<(start + marker.count)]) == marker {
            lastZrinitAt = Date()
            return
        }
    }

    private func applyTransfer(_ step: ZmodemStep) {
        if !step.outgoing.isEmpty {
            serialPort?.write(step.outgoing)
        }
        if var progress = step.progress {
            if progress.phase == .waiting, launchedRemote {
                progress.phase = .launching
            }
            onTransferProgress?(progress)
            armTransferTimeout()
        } else if step.status != nil {
            armTransferTimeout()
        }
        if let failure = step.failure {
            finishTransfer(failure, success: false)
            return
        }
        if let finished = step.finished {
            finishTransfer(finished, success: true)
        }
    }

    private func armTransferTimeout() {
        transferTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishTransfer("没有收到 rz 的应答。请确认当前是 shell 提示符，并且系统里有 rz", success: false)
        }
        transferTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func finishTransfer(_ message: String, success: Bool) {
        transferTimer?.cancel()
        transferTimer = nil
        transfer = nil
        launchedRemote = false
        onTransferProgress?(nil)
        serialTerminal?.feed(text: "\r\n[\(message)]\r\n")
        if !success {
            serialPort?.write(Array(repeating: ZmodemKind.zdle, count: 8))
        }
    }

    private func cancelTransfer() {
        transferTimer?.cancel()
        transferTimer = nil
        transfer = nil
        launchedRemote = false
        onTransferProgress?(nil)
    }

    fileprivate func sendSerial(_ data: ArraySlice<UInt8>, source: TerminalView) {
        guard transfer == nil else { return }
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
