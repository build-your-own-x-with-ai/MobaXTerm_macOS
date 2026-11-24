import AppKit
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    var controllers: [TerminalController]
    var selectedID: UUID?
    var onDropFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let focusChanged = context.coordinator.lastSelected != selectedID
        context.coordinator.lastSelected = selectedID
        nsView.onDropFiles = onDropFiles
        nsView.sync(controllers: controllers, selectedID: selectedID, focus: focusChanged)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastSelected: UUID?
    }
}

final class TerminalContainerView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    private var controllers: [TerminalController] = []
    private var selectedID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func sync(controllers: [TerminalController], selectedID: UUID?, focus: Bool) {
        self.controllers = controllers
        self.selectedID = selectedID
        let wanted = Set(controllers.map { ObjectIdentifier($0.view) })
        for subview in subviews where !wanted.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }
        for controller in controllers {
            let terminal = controller.view
            if terminal.superview !== self {
                terminal.autoresizingMask = [.width, .height]
                addSubview(terminal)
            }
            terminal.frame = bounds
            terminal.isHidden = controller.id != selectedID
        }
        layoutTerminals()
        guard focus, let selected = controllers.first(where: { $0.id == selectedID }) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(selected.view)
        }
    }

    override func layout() {
        super.layout()
        layoutTerminals()
    }

    private func layoutTerminals() {
        guard bounds.width > 2, bounds.height > 2 else { return }
        for controller in controllers {
            controller.view.frame = bounds
            controller.ensureStarted()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}
