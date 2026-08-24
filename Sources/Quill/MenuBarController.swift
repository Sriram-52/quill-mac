import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: Settings
    private var statusText = "Starting…"

    /// Supplied by the app: the app currently being watched, for the
    /// "Disable for <app>" menu item.
    var targetAppProvider: () -> (name: String, bundleID: String)? = { nil }

    init(settings: Settings) {
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Quill")
                ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: "Quill")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func setStatus(_ text: String) {
        statusText = text
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: settings.isPaused ? "Resume Checking" : "Pause Checking",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pause.target = self
        menu.addItem(pause)

        let passive = NSMenuItem(
            title: "Check While Typing (badge)",
            action: #selector(togglePassive),
            keyEquivalent: ""
        )
        passive.target = self
        passive.state = settings.passiveEnabled ? .on : .off
        menu.addItem(passive)

        if let target = targetAppProvider(), !settings.denylist.contains(target.bundleID) {
            let item = NSMenuItem(
                title: "Disable for \(target.name)",
                action: #selector(denyTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target.bundleID
            menu.addItem(item)
        }

        if !settings.denylist.isEmpty {
            let submenu = NSMenu()
            for bundleID in settings.denylist.sorted() {
                let item = NSMenuItem(title: bundleID, action: #selector(allowApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundleID
                submenu.addItem(item)
            }
            let holder = NSMenuItem(title: "Disabled Apps (click to re-enable)", action: nil, keyEquivalent: "")
            menu.addItem(holder)
            menu.setSubmenu(submenu, for: holder)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func togglePause() {
        settings.isPaused.toggle()
    }

    @objc private func togglePassive() {
        settings.passiveEnabled.toggle()
    }

    @objc private func denyTarget(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        settings.deny(bundleID)
    }

    @objc private func allowApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        settings.allow(bundleID)
    }
}
