import Darwin
import Foundation

enum SerialPortError: LocalizedError {
    case openFailed(path: String, code: Int32)
    case configureFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(path, code):
            return "无法打开 \(path)：\(String(cString: strerror(code)))"
        case let .configureFailed(message):
            return message
        }
    }
}

/// Owns one callout device. The descriptor stays non-blocking so the
/// DispatchSource read loop can drain until `EAGAIN`.
final class SerialPort {
    var onData: (([UInt8]) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let queue = DispatchQueue(label: "local.mobaxterm.serial")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var closing = false
    private var life: Life = .open
    private var closeWaiters: [() -> Void] = []

    private enum Life {
        case open
        case closing
        case closed
    }

    func open(path: String, settings: SerialSettings) throws {
        let opened = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard opened >= 0 else {
            throw SerialPortError.openFailed(path: path, code: errno)
        }
        fd = opened
        do {
            try configure(fd: opened, settings: settings)
        } catch {
            Darwin.close(opened)
            fd = -1
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: opened, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            self?.closeDescriptor()
        }
        readSource = source
        source.resume()
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            self?.writeAll(bytes)
        }
    }

    func setDataTerminalReady(_ enabled: Bool) {
        queue.sync {
            updateModem(mask: Int32(TIOCM_DTR), enabled: enabled)
        }
    }

    func setRequestToSend(_ enabled: Bool) {
        queue.sync {
            updateModem(mask: Int32(TIOCM_RTS), enabled: enabled)
        }
    }

    func modemLines() -> (dtr: Bool, rts: Bool) {
        queue.sync {
            var bits: Int32 = 0
            guard fd >= 0, ioctl(fd, UInt(TIOCMGET), &bits) == 0 else {
                return (true, true)
            }
            return ((bits & Int32(TIOCM_DTR)) != 0, (bits & Int32(TIOCM_RTS)) != 0)
        }
    }

    /// Cancels the read source and closes the descriptor before returning on the main thread.
    func close(completion: (() -> Void)? = nil) {
        queue.async {
            self.requestClose {
                guard let completion else { return }
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func configure(fd: Int32, settings: SerialSettings) throws {
        var term = termios()
        guard tcgetattr(fd, &term) == 0 else {
            throw SerialPortError.configureFailed("无法读取串口参数：\(String(cString: strerror(errno)))")
        }
        applySerialLineSettings(settings, to: &term)
        if let speed = posixSpeed(for: settings.baudRate) {
            cfsetispeed(&term, speed)
            cfsetospeed(&term, speed)
        }
        guard tcsetattr(fd, TCSANOW, &term) == 0 else {
            throw SerialPortError.configureFailed("无法设置串口参数：\(String(cString: strerror(errno)))")
        }
        var speed = speed_t(settings.baudRate)
        // IOSSIOSPEED is _IOW('T', 2, speed_t). Swift does not import that macro.
        let iossIOSpeed: UInt = 0x80085402
        if ioctl(fd, iossIOSpeed, &speed) != 0, posixSpeed(for: settings.baudRate) == nil {
            throw SerialPortError.configureFailed("无法设置波特率 \(settings.baudRate)：\(String(cString: strerror(errno)))")
        }
        tcflush(fd, TCIOFLUSH)
    }

    private func readAvailable() {
        guard fd >= 0, !closing else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while fd >= 0 && !closing {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count > 0 {
                onData?(Array(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                finishDisconnect("设备已断开")
                return
            }
            let error = errno
            if error == EAGAIN || error == EWOULDBLOCK {
                return
            }
            if error == EINTR {
                continue
            }
            finishDisconnect(String(cString: strerror(error)))
            return
        }
    }

    private func writeAll(_ bytes: [UInt8]) {
        guard fd >= 0, !closing else { return }
        var offset = 0
        var waits = 0
        while offset < bytes.count && fd >= 0 && !closing {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                waits = 0
                continue
            }
            let error = errno
            if written < 0 && error == EINTR {
                continue
            }
            if written < 0 && (error == EAGAIN || error == EWOULDBLOCK) {
                waits += 1
                if waits > 40 {
                    finishDisconnect("写入超时")
                    return
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 50)
                continue
            }
            finishDisconnect(String(cString: strerror(error)))
            return
        }
    }

    private func updateModem(mask: Int32, enabled: Bool) {
        guard fd >= 0 else { return }
        var bits: Int32 = 0
        guard ioctl(fd, UInt(TIOCMGET), &bits) == 0 else { return }
        if enabled {
            bits |= mask
        } else {
            bits &= ~mask
        }
        _ = ioctl(fd, UInt(TIOCMSET), &bits)
    }

    private func finishDisconnect(_ message: String) {
        let notify = onDisconnect
        requestClose {}
        notify?(message)
    }

    private func requestClose(completion: @escaping () -> Void) {
        closeWaiters.append(completion)
        if life == .closed {
            flushCloseWaiters()
            return
        }
        if life == .closing {
            return
        }
        life = .closing
        closing = true
        onData = nil
        onDisconnect = nil
        let finish = {
            self.closeDescriptor()
            self.life = .closed
            self.flushCloseWaiters()
        }
        if let source = readSource {
            readSource = nil
            source.setCancelHandler(handler: finish)
            source.cancel()
        } else {
            finish()
        }
    }

    private func closeDescriptor() {
        guard fd >= 0 else { return }
        let descriptor = fd
        fd = -1
        Darwin.close(descriptor)
    }

    private func flushCloseWaiters() {
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0() }
    }
}
