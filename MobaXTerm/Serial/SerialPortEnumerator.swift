import Foundation
import IOKit
import IOKit.serial

struct SerialDevice: Identifiable, Equatable {
    var path: String
    var name: String
    var hasProductName: Bool

    var id: String { path }
}

final class SerialPortMonitor {
    var onChange: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var stopped = false

    func start() {
        guard notifyPort == nil else { return }
        stopped = false
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            notifyPort = nil
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let context = Unmanaged.passUnretained(self).toOpaque()
        var added: io_iterator_t = 0
        var removed: io_iterator_t = 0
        let addedMatch = IOServiceMatching(kIOSerialBSDServiceValue)
        let removedMatch = IOServiceMatching(kIOSerialBSDServiceValue)
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            addedMatch,
            serialPortMatchCallback,
            context,
            &added
        )
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            removedMatch,
            serialPortMatchCallback,
            context,
            &removed
        )
        addedIterator = added
        removedIterator = removed
        drainSerialIterator(added)
        drainSerialIterator(removed)
    }

    func stop() {
        stopped = true
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    fileprivate func deliverChange() {
        guard !stopped else { return }
        onChange?()
    }

    static func listPorts() -> [SerialDevice] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [SerialDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let current = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(current) }
            guard let path = registryString(current, key: kIOCalloutDeviceKey), path.hasPrefix("/dev/cu.") else {
                continue
            }
            let product = productName(for: current)
            let name = product ?? URL(fileURLWithPath: path).lastPathComponent
            devices.append(SerialDevice(path: path, name: name, hasProductName: product != nil))
        }
        devices.sort { lhs, rhs in
            if lhs.hasProductName != rhs.hasProductName {
                return lhs.hasProductName && !rhs.hasProductName
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return devices
    }
}

private func drainSerialIterator(_ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

private let serialPortMatchCallback: IOServiceMatchingCallback = { refcon, iterator in
    drainSerialIterator(iterator)
    guard let refcon else { return }
    let monitor = Unmanaged<SerialPortMonitor>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.deliverChange()
    }
}

private func registryString(_ entry: io_registry_entry_t, key: String) -> String? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    return unmanaged.takeRetainedValue() as? String
}

private func productName(for service: io_object_t) -> String? {
    var node = service
    var owned: [io_object_t] = []
    defer { owned.forEach { IOObjectRelease($0) } }
    for _ in 0..<12 {
        if let name = registryString(node, key: "USB Product Name"), !name.isEmpty {
            return name
        }
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        owned.append(parent)
        node = parent
    }
    return nil
}
