import AppKit
import ApplicationServices

@MainActor
enum TextReplacer {
    /// Replace the selection in the target app: Accessibility API first,
    /// clipboard-paste fallback for apps (mostly Electron) that don't honor it.
    static func replace(selection: TextSelection, with replacement: String) {
        if selection.wholeField {
            replaceWholeField(selection, with: replacement)
            return
        }
        if axReplace(selection, with: replacement) { return }
        pasteFallback(replacement, pid: selection.pid)
    }

    /// Badge mode: swap the field's entire value. AX value write when honored,
    /// else select-all + paste.
    private static func replaceWholeField(_ selection: TextSelection, with replacement: String) {
        let element = selection.element
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFTypeRef) == .success,
           AX.value(of: element) == replacement {
            return
        }
        // Select everything, then paste over it.
        let current = AX.value(of: element) ?? selection.text
        var fullRange = CFRange(location: 0, length: (current as NSString).length)
        if let rangeValue = AXValueCreate(.cfRange, &fullRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }
        // Belt and suspenders for apps that ignore the range write: ⌘A.
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyA: CGKeyCode = 0x00
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        pasteFallback(replacement, pid: selection.pid)
    }

    private static func axReplace(_ selection: TextSelection, with replacement: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            selection.element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return false }

        guard AXUIElementSetAttributeValue(
            selection.element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef
        ) == .success else { return false }

        // Chromium/Electron report success without applying. If the selection
        // still holds the original text, the write silently failed.
        if let after = AX.selectedText(of: selection.element),
           after == selection.text, replacement != selection.text {
            return false
        }
        return true
    }

    private static func pasteFallback(_ text: String, pid: pid_t) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Make sure the target app is frontmost before the synthetic ⌘V —
        // clicking our non-activating panel shouldn't have changed that, but
        // be explicit.
        NSRunningApplication(processIdentifier: pid)?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyV: CGKeyCode = 0x09
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            // Session-level post reaches Chromium/Electron apps that ignore
            // events posted directly to their pid.
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
        }
    }
}
