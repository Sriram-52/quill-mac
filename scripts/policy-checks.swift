// Decision-table checks for FieldPolicy. Run with scripts/check-policy.sh.
// Compiled as a standalone main file alongside the real AXSupport,
// Settings and FieldPolicy sources.
import Foundation

@MainActor
func run() {
    // Isolate from the real app's saved settings.
    UserDefaults.standard.removePersistentDomain(forName: "policytest")
    let policy = FieldPolicy(settings: Settings())
    var failures = 0

    func check(_ label: String,
               _ surface: FieldSurface,
               _ names: [String],
               bundleID: String? = "com.example.app",
               ancestors: [String] = [],
               expect: Bool) {
        let ctx = FieldPolicy.FieldContext(
            surface: surface, bundleID: bundleID, names: names,
            ancestorNames: { names + ancestors }
        )
        let d = policy.evaluate(ctx)
        let ok = d.isAllowed == expect
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(label): allowed=\(d.isAllowed) (\(d.reason))")
    }

    print("— gate 1: role —")
    check("plain text area", .prose, ["Message Body"], expect: true)
    check("Arc address bar", .singleLine, ["Address and search bar"],
          bundleID: "company.thebrowser.Browser", expect: false)
    check("Chrome omnibox", .singleLine, ["Search Google or type a URL"],
          bundleID: "com.google.Chrome", expect: false)
    check("unnamed single-line field", .singleLine, [], expect: false)
    check("search field / label", .ineligible, ["anything"], expect: false)

    print("\n— gate 2: rules —")
    check("Mail subject line", .singleLine, ["Subject"],
          bundleID: "com.apple.mail", expect: true)
    check("Outlook subject line", .singleLine, ["Subject"],
          bundleID: "com.microsoft.Outlook", expect: true)
    check("Mail 'To' field still refused? (rule allows subject only)", .singleLine, ["To"],
          bundleID: "com.apple.mail", expect: false)
    check("Mail subject under a 'Re: your account' window title", .singleLine,
          ["Subject"], bundleID: "com.apple.mail",
          ancestors: ["Re: your account - Inbox"], expect: true)
    check("Safari field named 'url'", .prose, ["url"],
          bundleID: "com.apple.Safari", expect: false)

    print("\n— gate 3: name blocklist —")
    check("password box (prose role)", .prose, ["Password"], expect: false)
    check("API key text area", .prose, ["api_key"], expect: false)
    check("card number", .prose, ["Card Number"], expect: false)
    check("prose area named 'date'", .prose, ["date"], expect: true)
    check("prose area named 'search'", .prose, ["Search notes"], expect: true)
    check("Apple Notes Note[id=..]", .prose, ["Note[id=1234]"],
          bundleID: "com.apple.Notes", expect: true)
    check("login ancestor does NOT block prose", .prose, ["Comment"],
          ancestors: ["Sign in to your account"], expect: true)

    print("\n— gate 0: app denylist —")
    let denied = Settings()
    denied.deny("com.example.denied")
    let deniedPolicy = FieldPolicy(settings: denied)
    let dCtx = FieldPolicy.FieldContext(surface: .prose, bundleID: "com.example.denied", names: ["Message Body"])
    let dRes = deniedPolicy.evaluate(dCtx)
    print("\(!dRes.isAllowed ? "ok  " : "FAIL") disabled app, prose surface: allowed=\(dRes.isAllowed) (\(dRes.reason))")
    if dRes.isAllowed { failures += 1 }
    denied.allow("com.example.denied")

    print("\n— gate 4: per-app opt-in —")
    let settings = Settings()
    settings.setAllowsSingleLine(true, for: "com.example.optin")
    let opted = FieldPolicy(settings: settings)
    let ctx = FieldPolicy.FieldContext(surface: .singleLine, bundleID: "com.example.optin", names: ["Title"])
    let d = opted.evaluate(ctx)
    print("\(d.isAllowed ? "ok  " : "FAIL") opted-in app, single-line: allowed=\(d.isAllowed) (\(d.reason))")
    if !d.isAllowed { failures += 1 }
    for (label, names, ancestors) in [
        ("password", ["Password"], [String]()),
        ("'Full Name'", ["Full Name"], []),
        ("field under a 'Sign in' ancestor", ["Username"], ["Sign in to your account"]),
        ("'To' header", ["To"], []),
    ] {
        let c = FieldPolicy.FieldContext(surface: .singleLine, bundleID: "com.example.optin",
                                         names: names, ancestorNames: { names + ancestors })
        let r = opted.evaluate(c)
        print("\(!r.isAllowed ? "ok  " : "FAIL") opted-in app, \(label): allowed=\(r.isAllowed) (\(r.reason))")
        if r.isAllowed { failures += 1 }
    }
    let ctxBad = FieldPolicy.FieldContext(surface: .singleLine, bundleID: "com.example.optin", names: ["Body"])
    let dBad = opted.evaluate(ctxBad)
    print("\(dBad.isAllowed ? "ok  " : "FAIL") opted-in app, innocuous 'Body': allowed=\(dBad.isAllowed) (\(dBad.reason))")
    if !dBad.isAllowed { failures += 1 }
    settings.setAllowsSingleLine(false, for: "com.example.optin")

    print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
    exit(failures == 0 ? 0 : 1)
}

@main
enum PolicyChecks {
    static func main() {
        MainActor.assumeIsolated { run() }
    }
}
