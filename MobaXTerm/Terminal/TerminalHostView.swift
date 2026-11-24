import AppKit
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    var controllers: [TerminalController]
    var selectedID: UUID?

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let focusChanged = context.coordinator.lastSelected != selectedID
        context.coordinator.lastSelected = selectedID
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
    private var controllers: [TerminalController] = []
    private var selectedID: UUID?

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
}
