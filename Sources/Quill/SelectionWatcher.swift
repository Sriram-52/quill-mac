import AppKit
import ApplicationServices

private let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<SelectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        watcher.handleAXNotification(name)
    }
}

/// Follows the frontmost app and reports debounced text selections in it.
@MainActor
final class SelectionWatcher {
    var onSelection: ((TextSelection) -> Void)?
    /// Debounced full-field text while the user types (passive badge mode).
    var onTyping: ((TypingContext) -> Void)?
    /// Fired when focus moves to another field or app — dismiss card and badge.
    var onFocusChanged: (() -> Void)?
    /// Fired when the selection empties — dismiss the card, keep the badge.
    var onSelectionCleared: (() -> Void)?

    private(set) var currentTarget: (name: String, bundleID: String)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedPid: pid_t = 0
    private var observedBundleID: String?
    private var observedAppName: String?
    private var debounceTask: Task<Void, Never>?
    private var typingDebounceTask: Task<Void, Never>?
    private var suppressUntil = Date.distantPast
    private var workspaceToken: NSObjectProtocol?

    func start() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.attach(to: app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            attach(to: front)
        }
    }

    /// Ignore selection events briefly (e.g. right after we replace text).
    func suppress(for seconds: TimeInterval) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    fileprivate func handleAXNotification(_ name: String) {
        if name == kAXFocusedUIElementChangedNotification {
            debounceTask?.cancel()
            typingDebounceTask?.cancel()
            onFocusChanged?()
        } else if name == kAXSelectedTextChangedNotification {
            scheduleRead()
            // Chromium web fields often never emit value-changed; the caret
            // moving on each keystroke emits selection-changed instead, so it
            // doubles as the typing signal. emitTyping() guards on an empty
            // selection and a non-empty field, so this stays cheap and safe.
            scheduleTypingRead()
        } else if name == kAXValueChangedNotification {
            scheduleTypingRead()
        }
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard pid != observedPid else { return }
        detach()
        onFocusChanged?()

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        // Chromium browsers and Electron apps keep their accessibility tree
        // disabled until an assistive client asks for it. These two app-level
        // attributes are the documented way to switch it on (Chrome honors
        // AXEnhancedUserInterface, Electron honors AXManualAccessibility).
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXSelectedTextChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXValueChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        observer = obs
        appElement = appEl
        observedPid = pid
        observedBundleID = app.bundleIdentifier
        observedAppName = app.localizedName
        if let bid = app.bundleIdentifier {
            currentTarget = (name: app.localizedName ?? bid, bundleID: bid)
        }
    }

    private func detach() {
        debounceTask?.cancel()
        typingDebounceTask?.cancel()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        observedPid = 0
        observedBundleID = nil
        observedAppName = nil
    }

    private func scheduleRead() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.emitSelection()
        }
    }

    /// Typing pauses longer than selection: give the user time to finish a
    /// thought before checking the whole field.
    private func scheduleTypingRead() {
        typingDebounceTask?.cancel()
        typingDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.emitTyping()
        }
    }

    private func emitTyping() {
        guard Date() >= suppressUntil, let appElement else { return }
        guard let element = AX.focusedElement(in: appElement),
              !AX.isSecure(element), AX.isEditable(element) else { return }
        // An active selection belongs to the selection flow, not typing.
        guard (AX.selectedText(of: element) ?? "").isEmpty else { return }
        guard let text = AX.value(of: element), !text.isEmpty else { return }
        onTyping?(TypingContext(
            text: text,
            element: element,
            pid: observedPid,
            bundleID: observedBundleID,
            appName: observedAppName,
            fieldFrame: AX.frameCocoa(of: element)
        ))
    }

    private func emitSelection() {
        guard Date() >= suppressUntil, let appElement else { return }
        guard let element = AX.focusedElement(in: appElement) else {
            onSelectionCleared?()
            return
        }
        guard !AX.isSecure(element) else { return }
        guard AX.isEditable(element) else {
            onSelectionCleared?()
            return
        }
        let text = AX.selectedText(of: element) ?? ""
        guard !text.isEmpty else {
            onSelectionCleared?()
            return
        }
        onSelection?(TextSelection(
            text: text,
            element: element,
            pid: observedPid,
            bundleID: observedBundleID,
            appName: observedAppName,
            anchorRect: anchorRect(for: element)
        ))
    }

    /// Electron/Chromium apps often report nonsense selection bounds. Trust
    /// the AX rect only when it's plausibly sized, on-screen, and near the
    /// mouse; otherwise anchor at the mouse position (which, right after a
    /// selection, is where the user is looking).
    private func anchorRect(for element: AXUIElement) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let mouseRect = CGRect(x: mouse.x - 2, y: mouse.y - 2, width: 4, height: 4)
        guard let rect = AX.selectionBoundsCocoa(of: element),
              rect.width >= 1, rect.height >= 4,
              rect.width <= 4000, rect.height <= 2000,
              NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else {
            return mouseRect
        }
        let dx = rect.midX - mouse.x
        let dy = rect.midY - mouse.y
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance <= 600 ? rect : mouseRect
    }
}
