import Foundation

@MainActor
final class Settings {
    private let defaults = UserDefaults.standard
    private static let pausedKey = "quill.paused"
    private static let denylistKey = "quill.denylist"
    private static let seededKey = "quill.denylist.seeded"
    private static let singleLineKey = "quill.singleLineApps"

    /// Apps where grammar cards are noise, disabled out of the box.
    /// Re-enable any of them from the menu.
    private static let defaultDenylist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
    ]

    private(set) var denylist: Set<String>

    /// Apps where single-line text fields are checked too. Off everywhere by
    /// default: address bars, login boxes and form controls are all
    /// single-line, and a card over any of them is pure noise. See
    /// `FieldPolicy` for the rest of the gate.
    private(set) var singleLineApps: Set<String>

    var isPaused: Bool {
        get { defaults.bool(forKey: Self.pausedKey) }
        set { defaults.set(newValue, forKey: Self.pausedKey) }
    }

    private static let passiveKey = "quill.passiveChecking"

    /// Badge mode: check the focused field while typing. On by default.
    var passiveEnabled: Bool {
        get { defaults.object(forKey: Self.passiveKey) == nil ? true : defaults.bool(forKey: Self.passiveKey) }
        set { defaults.set(newValue, forKey: Self.passiveKey) }
    }

    init() {
        if !defaults.bool(forKey: Self.seededKey) {
            defaults.set(Self.defaultDenylist, forKey: Self.denylistKey)
            defaults.set(true, forKey: Self.seededKey)
        }
        denylist = Set(defaults.stringArray(forKey: Self.denylistKey) ?? [])
        singleLineApps = Set(defaults.stringArray(forKey: Self.singleLineKey) ?? [])
    }

    func deny(_ bundleID: String) {
        denylist.insert(bundleID)
        persist()
    }

    func allow(_ bundleID: String) {
        denylist.remove(bundleID)
        persist()
    }

    func isDenied(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return denylist.contains(bundleID)
    }

    func setAllowsSingleLine(_ allowed: Bool, for bundleID: String) {
        if allowed {
            singleLineApps.insert(bundleID)
        } else {
            singleLineApps.remove(bundleID)
        }
        defaults.set(Array(singleLineApps).sorted(), forKey: Self.singleLineKey)
    }

    func allowsSingleLine(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return singleLineApps.contains(bundleID)
    }

    private func persist() {
        defaults.set(Array(denylist).sorted(), forKey: Self.denylistKey)
    }
}
