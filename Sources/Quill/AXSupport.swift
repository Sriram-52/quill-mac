import AppKit
import ApplicationServices
import os

/// Diagnostics: `log show --last 5m --predicate 'subsystem == "dev.codebyram.quill"'`
let qlog = Logger(subsystem: "dev.codebyram.quill", category: "quill")

/// A snapshot of a text selection in another app, captured at check time.
struct TextSelection {
    let text: String
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    /// Where to anchor the popup, in Cocoa screen coordinates. Always valid:
    /// the AX selection bounds when trustworthy, else the mouse position
    /// captured at selection time.
    let anchorRect: CGRect
    /// True when this "selection" is really the whole field (badge mode) —
    /// Accept then replaces the field's entire value, not a selection.
    var wholeField: Bool = false
}

/// A snapshot of a text field being typed in, for passive badge checks.
struct TypingContext {
    let text: String
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    /// Field frame in Cocoa screen coordinates, if the app reports it.
    let fieldFrame: CGRect?
}

enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    static func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    static func selectedText(of element: AXUIElement) -> String? {
        attribute(element, kAXSelectedTextAttribute)
    }

    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute)
    }

    /// The element's frame converted to Cocoa (bottom-left origin) screen
    /// coordinates. Far more reliable than per-range bounds, even in Electron.
    static func frameCocoa(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((posRef as! AXValue), .cgPoint, &point),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size),
              size.width > 0, size.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        let y = primary.frame.height - (point.y + size.height)
        return CGRect(x: point.x, y: y, width: size.width, height: size.height)
    }

    static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    static func subrole(of element: AXUIElement) -> String? {
        attribute(element, kAXSubroleAttribute)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        role(of: element) == "AXSecureTextField" || subrole(of: element) == "AXSecureTextField"
    }

    /// Whether the element plausibly accepts text edits. Read-only text
    /// (labels, rendered chat transcripts, web page prose) should get no
    /// card at all. Signals are layered because Electron/Chromium and native
    /// apps report editability differently.
    static func isEditable(_ element: AXUIElement) -> Bool {
        switch role(of: element) {
        case "AXStaticText":
            return false
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return true
        default:
            break
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // WebKit/Chromium expose this on nodes inside contenteditable regions.
        if let _: CFTypeRef = attribute(element, "AXEditableAncestor") {
            return true
        }
        return false
    }

    /// Bounds of the current selection, converted from AX (top-left origin,
    /// global) to Cocoa (bottom-left origin) screen coordinates.
    static func selectionBoundsCocoa(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((boundsRef as! AXValue), .cgRect, &rect), rect != .zero else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let y = primary.frame.height - rect.maxY
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }
}
