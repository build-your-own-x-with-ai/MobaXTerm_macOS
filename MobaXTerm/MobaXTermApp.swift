import AppKit
import SwiftUI

extension Notification.Name {
    static let mobaCloseSelectedTab = Notification.Name("local.mobaxterm.closeSelectedTab")
    static let mobaOpenLocalTerminal = Notification.Name("local.mobaxterm.openLocalTerminal")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        DispatchQueue.main.async {
            MenuInstaller.install()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MenuInstaller.install()
    }
}

enum MenuInstaller {
    static func install() {
        func walk(_ menu: NSMenu?) {
            guard let menu else { return }
            for item in menu.items {
                let modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if item.keyEquivalent == "w", modifiers == .command {
                    item.title = "关闭标签"
                    item.action = #selector(AppDelegate.closeSelectedTab(_:))
                    item.target = NSApp.delegate
                }
                walk(item.submenu)
            }
        }
        walk(NSApp.mainMenu)
    }
}

extension AppDelegate {
    @objc func closeSelectedTab(_ sender: Any?) {
        NotificationCenter.default.post(name: .mobaCloseSelectedTab, object: nil)
    }
}

@main
struct MobaXTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: .mobaCloseSelectedTab)) { _ in
                    model.closeSelectedTab()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.beginNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("本地终端") { model.openLocalTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("重新连接") { model.reconnectSelected() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedTabID == nil)
            }
        }
    }
}
