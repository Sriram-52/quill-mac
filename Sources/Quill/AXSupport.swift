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

/// The three ways Quill can treat a focused element. Modeled on Grammarly
/// Desktop's rule engine, where every single-line field is off until a rule
/// explicitly opts it in.
enum FieldSurface {
    /// Multi-line editors and contenteditable regions: checked by default.
    case prose
    /// Single-line text fields and combo boxes: off unless the app is opted
    /// in, because this is the shape of address bars and login forms.
    case singleLine
    /// Search fields, labels, and anything that will not accept a write.
    case ineligible
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

    /// Where a focused element sits on the spectrum from "prose the user is
    /// writing" to "a one-line control that merely holds text". Role alone was
    /// never enough: a browser address bar, a login box, and a Gmail subject
    /// line are all `AXTextField`, which is why single-line controls are their
    /// own category rather than simply "editable".
    static func surface(of element: AXUIElement) -> FieldSurface {
        if isSecure(element) { return .ineligible }
        let role = role(of: element)
        let subrole = subrole(of: element)
        if subrole == "AXSearchField" { return .ineligible }
        switch role {
        case "AXStaticText", "AXSearchField", "AXMenuItem", "AXButton", "AXCheckBox", "AXRadioButton":
            return .ineligible
        case "AXTextArea":
            return .prose
        case "AXTextField", "AXComboBox":
            return .singleLine
        default:
            break
        }
        // WebKit/Chromium expose this on nodes inside contenteditable regions.
        if let _: CFTypeRef = attribute(element, "AXEditableAncestor") {
            return .prose
        }
        // Custom native and Electron views report roles we do not recognise.
        // If they will accept a write, treat them as prose: the named
        // single-line roles were already ruled out above.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .prose
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .prose
        }
        return .ineligible
    }

    /// Attributes that carry a human- or developer-assigned name for the
    /// element. The name blocklist matches against all of them, because apps
    /// disagree about which one they populate: native apps favour `AXTitle`,
    /// web content usually only has `AXDOMIdentifier` or a placeholder.
    private static let nameAttributes = [
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXPlaceholderValueAttribute,
        kAXIdentifierAttribute,
        "AXDOMIdentifier",
    ]

    static func names(of element: AXUIElement) -> [String] {
        nameAttributes.compactMap { name -> String? in
            guard let value: String = attribute(element, name), !value.isEmpty else { return nil }
            return value
        }
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// The element's own names plus those of its nearest ancestors, up to
    /// `depth` levels. Window titles come along for the ride at the top of the
    /// chain, which is what catches a field sitting on a page titled "Sign in".
    static func namesIncludingAncestors(of element: AXUIElement, depth: Int = 6) -> [String] {
        var collected = names(of: element)
        var current = element
        for _ in 0..<depth {
            guard let next = parent(of: current) else { break }
            collected.append(contentsOf: names(of: next))
            current = next
        }
        return collected
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
