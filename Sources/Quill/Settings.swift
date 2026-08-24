import Foundation

@MainActor
final class Settings {
    private let defaults = UserDefaults.standard
    private static let pausedKey = "quill.paused"
    private static let denylistKey = "quill.denylist"
    private static let seededKey = "quill.denylist.seeded"

    /// Apps where grammar cards are noise, disabled out of the box.
    /// Re-enable any of them from the menu.
    private static let defaultDenylist = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
    ]

    private(set) var denylist: Set<String>

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

    private func persist() {
        defaults.set(Array(denylist).sorted(), forKey: Self.denylistKey)
    }
}
