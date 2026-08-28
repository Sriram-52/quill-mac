import ApplicationServices
import Foundation

/// One override rule. Matching is by regex so a single entry can cover a
/// family of apps or elements. A `nil` field matches anything.
///
/// Shape borrowed from Grammarly Desktop's `IntegrationOptions.json`, trimmed
/// to what a local-only tool needs: no domain/path matching, because Quill
/// never learns the URL of the page inside a browser.
struct FieldRule: Decodable {
    /// Regex against the app's bundle identifier.
    var bundleID: String?
    /// Regex against the element's accessibility name.
    var elementName: String?
    /// Match `elementName` against ancestors and the window title too.
    var checkAncestors: Bool?
    /// Permit single-line text fields and combo boxes in this app.
    var allowSingleLine: Bool?
    /// Skip the name blocklist here, for surfaces it wrongly suppresses.
    var ignoreNameBlocklist: Bool?
    /// `false` refuses the surface outright, whatever else matches.
    var isEnabled: Bool?
    var notes: String?
}

/// Why a field was accepted or refused. Carried into the log so a surprising
/// decision can be traced without a debugger.
struct PolicyDecision {
    let isAllowed: Bool
    let reason: String
}

/// Decides whether a focused element deserves a card or a badge.
///
/// Five gates, in order:
///  0. The app denylist, so a disabled app costs nothing.
///  1. Role. Prose surfaces pass; single-line controls need an opt-in; search
///     fields, labels and read-only views never pass.
///  2. Override rules, bundled below and extensible from a user file.
///  3. The name blocklist: credentials everywhere, personal-info and login
///     wording on single-line fields.
///  4. The per-app toggle in the menu bar, which is the escape hatch when the
///     blocklist gets it wrong.
@MainActor
final class FieldPolicy {
    private let settings: Settings
    private let rules: [FieldRule]
    private var regexCache: [String: NSRegularExpression] = [:]

    init(settings: Settings) {
        self.settings = settings
        self.rules = Self.defaultRules + Self.userRules()
    }

    // MARK: - Rules

    /// Surfaces worth a rule out of the box. Everything here is a single-line
    /// field that carries real prose, which is the only category the role gate
    /// refuses for the wrong reason.
    static let defaultRules: [FieldRule] = [
        FieldRule(bundleID: #"^com\.apple\.mail$"#, elementName: #"^subject"#,
                  allowSingleLine: true, notes: "Mail subject line"),
        FieldRule(bundleID: #"^com\.microsoft\.Outlook$"#, elementName: #"^subject"#,
                  allowSingleLine: true, notes: "Outlook subject line"),
        // The login group walks ancestors, which includes the window title. A
        // compose window is titled after its subject, so replying to "your
        // account" would otherwise block the subject field we just allowed.
        FieldRule(bundleID: #"^com\.apple\.mail$|^com\.microsoft\.Outlook$"#,
                  ignoreNameBlocklist: true,
                  notes: "Mail window titles are message subjects, not form labels"),
        // Belt and braces. Browser chrome is single-line and so already off,
        // but an address bar is the one surface that must never be checked.
        FieldRule(bundleID: #"^com\.apple\.Safari$|^com\.google\.Chrome|^company\.thebrowser\.Browser$|^com\.brave\.Browser$|^org\.mozilla\.firefox$|^com\.microsoft\.edgemac$"#,
                  elementName: #"address|location|\burl\b|search|^omnibox$"#, isEnabled: false,
                  notes: "browser chrome is never a writing surface"),
    ]

    /// Optional user overrides, appended after the defaults so they win.
    /// Absent or malformed files are ignored: a typo here should cost the
    /// override, not the app.
    static func userRulesURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quill/FieldPolicy.json")
    }

    private static func userRules() -> [FieldRule] {
        let url = userRulesURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([FieldRule].self, from: data)
            qlog.notice("field policy: loaded \(decoded.count) user rule(s)")
            return decoded
        } catch {
            qlog.notice("field policy: user rules ignored, \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Name blocklist

    enum BlockScope {
        /// Applies to every surface, prose included.
        case everywhere
        /// Applies only to single-line fields, which is where these words
        /// nearly always mean a form control rather than a piece of writing.
        case singleLineOnly
    }

    struct NameBlockRule {
        let label: String
        let pattern: String
        let scope: BlockScope
        let checkAncestors: Bool
    }

    /// English only. Quill is a personal tool; add languages here if the fields
    /// you type in are named in one.
    ///
    /// The split by scope is deliberate. Grammarly applies its whole keyword
    /// list to every surface and then carries a long tail of per-app exemptions
    /// for the false positives (Apple Notes' `Note[id=...]`, ChatGPT's
    /// `mobile-composer-prompt`). Restricting the noisy half to single-line
    /// fields avoids most of that tail, because a multi-line editor named
    /// "date" or "number" is vanishingly rare.
    static let nameBlocklist: [NameBlockRule] = [
        NameBlockRule(
            label: "credential",
            pattern: #"\b(password|passwd|pwd|passphrase|secret|token|api[\s_-]?key|ssn|sin|ein|i?tin|tfn|ccn|ccv|cvv|cvc|otp)\b"#,
            scope: .everywhere, checkAncestors: false
        ),
        NameBlockRule(
            label: "payment",
            pattern: #"\b(credit\s?card|card\s?number|security\s?code|account\s?number|routing)\b"#,
            scope: .everywhere, checkAncestors: false
        ),
        NameBlockRule(
            label: "personal info",
            pattern: #"\bage\b|birth|city|\bcode\b|credit|\bdate\b|email|e-mail|mobile|\bname\b|number|phone|\bpin\b|search|user\s?id|\bzip\b|postal"#,
            scope: .singleLineOnly, checkAncestors: false
        ),
        NameBlockRule(
            label: "login",
            pattern: #"account|address|authentication|authorization|log\s?in|sign\s?in|sign\s?up|verification|two[\s-]?factor"#,
            scope: .singleLineOnly, checkAncestors: true
        ),
        NameBlockRule(
            label: "email header",
            pattern: #"(^(bcc|cc|find|link)\b)|(^to$)|(^from$)"#,
            scope: .singleLineOnly, checkAncestors: false
        ),
    ]

    // MARK: - Evaluation

    /// Everything the policy needs about a focused element, read from the
    /// Accessibility API once so the decision itself stays free of AX calls
    /// (and testable without a live app).
    struct FieldContext {
        let surface: FieldSurface
        let bundleID: String?
        let names: [String]
        /// Ancestor names, read lazily: the walk costs several AX round trips
        /// and most decisions never need it.
        let ancestorNames: () -> [String]

        init(surface: FieldSurface, bundleID: String?, names: [String],
             ancestorNames: @escaping () -> [String] = { [] }) {
            self.surface = surface
            self.bundleID = bundleID
            self.names = names
            self.ancestorNames = ancestorNames
        }
    }

    func evaluate(element: AXUIElement, bundleID: String?) -> PolicyDecision {
        evaluate(FieldContext(
            surface: AX.surface(of: element),
            bundleID: bundleID,
            names: AX.names(of: element),
            ancestorNames: { AX.namesIncludingAncestors(of: element) }
        ))
    }

    func evaluate(_ context: FieldContext) -> PolicyDecision {
        // Gate 0. Cheapest and most absolute: an app the user switched off.
        // Checked here rather than at the point of use so a disabled app costs
        // no field reads, and so the refusal shows up in the log like any other.
        if settings.isDenied(context.bundleID) {
            return PolicyDecision(isAllowed: false, reason: "app is disabled")
        }
        guard context.surface != .ineligible else {
            return PolicyDecision(isAllowed: false, reason: "not a writing surface")
        }

        var cachedAncestors: [String]?
        func haystack(checkAncestors: Bool) -> [String] {
            guard checkAncestors else { return context.names }
            if cachedAncestors == nil { cachedAncestors = context.ancestorNames() }
            return cachedAncestors ?? context.names
        }

        var allowSingleLine = settings.allowsSingleLine(context.bundleID)
        var ignoreNameBlocklist = false

        for rule in rules {
            guard matches(rule.bundleID, in: [context.bundleID ?? ""]) else { continue }
            if let pattern = rule.elementName {
                guard matches(pattern, in: haystack(checkAncestors: rule.checkAncestors == true)) else { continue }
            }
            if rule.isEnabled == false {
                return PolicyDecision(isAllowed: false, reason: "rule: \(rule.notes ?? "disabled")")
            }
            if let allow = rule.allowSingleLine { allowSingleLine = allow }
            if rule.ignoreNameBlocklist == true { ignoreNameBlocklist = true }
        }

        if context.surface == .singleLine && !allowSingleLine {
            return PolicyDecision(isAllowed: false, reason: "single-line field (enable for this app from the menu)")
        }

        if !ignoreNameBlocklist {
            for block in Self.nameBlocklist {
                if block.scope == .singleLineOnly && context.surface != .singleLine { continue }
                if matches(block.pattern, in: haystack(checkAncestors: block.checkAncestors)) {
                    return PolicyDecision(isAllowed: false, reason: "name looks like \(block.label)")
                }
            }
        }

        return PolicyDecision(isAllowed: true,
                              reason: context.surface == .prose ? "prose surface" : "single-line, opted in")
    }

    // MARK: - Regex

    private func matches(_ pattern: String?, in candidates: [String]) -> Bool {
        guard let pattern else { return true }
        guard let regex = regex(for: pattern) else { return false }
        return candidates.contains { candidate in
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, options: [], range: range) != nil
        }
    }

    private func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            qlog.notice("field policy: bad regex \(pattern, privacy: .public)")
            return nil
        }
        regexCache[pattern] = compiled
        return compiled
    }
}
