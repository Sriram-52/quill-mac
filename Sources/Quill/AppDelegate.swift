import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let engine = FoundationModelsEngine()
    private let panel = SuggestionPanelController()
    private let badge = BadgeController()
    private var menuBar: MenuBarController!
    private var watcher: SelectionWatcher?
    private var checkTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var trustTimer: Timer?
    /// Memo of the last check so re-selecting the same text is free.
    private var lastResult: (text: String, corrected: String)?
    private var lastTypingResult: (text: String, corrected: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(settings: settings)
        menuBar.targetAppProvider = { [weak self] in self?.watcher?.currentTarget }
        engine.prewarm()
        ensureAccessibility()
    }

    private func ensureAccessibility() {
        if !AXIsProcessTrusted() {
            clearStaleAccessibilityGrantOnce()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startWatching()
        } else {
            qlog.notice("accessibility not trusted yet")
            menuBar.setStatus("Waiting for Accessibility permission…")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    Task { @MainActor in self?.startWatching() }
                }
            }
        }
    }

    /// After an update the old Accessibility grant no longer matches this
    /// build's signature, so the toggle in System Settings looks "on" while
    /// Quill is untrusted. `tccutil reset` clears our own entry (no admin
    /// needed) so the normal prompt appears again. Runs at most once per build.
    private func clearStaleAccessibilityGrantOnce() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let key = "quill.tccResetBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            qlog.notice("tccutil reset Accessibility exited \(process.terminationStatus)")
        } catch {
            qlog.notice("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWatching() {
        qlog.notice("watching started; \(self.engine.statusDescription, privacy: .public)")
        menuBar.setStatus(engine.statusDescription)
        let watcher = SelectionWatcher()
        watcher.onSelection = { [weak self] selection in
            self?.handleSelection(selection)
        }
        watcher.onTyping = { [weak self] context in
            self?.handleTyping(context)
        }
        watcher.onFocusChanged = { [weak self] in
            self?.checkTask?.cancel()
            self?.typingTask?.cancel()
            self?.panel.dismiss()
            self?.badge.hide()
        }
        watcher.onSelectionCleared = { [weak self] in
            self?.checkTask?.cancel()
            self?.panel.dismiss()
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handleSelection(_ selection: TextSelection) {
        guard !settings.isPaused else { qlog.notice("check skipped: paused"); return }
        guard engine.isAvailable else { qlog.notice("check skipped: engine unavailable: \(self.engine.statusDescription, privacy: .public)"); return }
        guard !settings.isDenied(selection.bundleID) else { qlog.notice("check skipped: app denylisted"); return }

        let trimmed = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 2000,
              trimmed.rangeOfCharacter(from: .letters) != nil else {
            panel.dismiss()
            return
        }

        checkTask?.cancel()

        // Memoized: skip the spinner, answer instantly.
        if let memo = lastResult, memo.text == trimmed {
            present(selection: selection, trimmed: trimmed, corrected: memo.corrected)
            return
        }

        panel.showChecking(near: selection.anchorRect)
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                let corrected = try await engine.proofread(trimmed)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                qlog.notice("proofread done in \(Int(Date().timeIntervalSince(started) * 1000)) ms, changed: \(corrected != trimmed)")
                guard !Task.isCancelled else { return }
                lastResult = (text: trimmed, corrected: corrected)
                present(selection: selection, trimmed: trimmed, corrected: corrected)
            } catch {
                NSLog("Quill proofread failed: \(error)")
                panel.dismiss()
            }
        }
    }

    private func present(selection: TextSelection, trimmed: String, corrected: String) {
        guard !corrected.isEmpty, corrected != trimmed else {
            panel.showClean(cleanModel(for: selection, trimmed: trimmed), near: selection.anchorRect)
            return
        }
        let segments = WordDiff.suppressingPunctuationNormalization(WordDiff.diff(from: trimmed, to: corrected))
        guard WordDiff.hasChanges(segments) else {
            panel.showClean(cleanModel(for: selection, trimmed: trimmed), near: selection.anchorRect)
            return
        }
        presentCard(for: selection, trimmed: trimmed, corrected: WordDiff.result(from: segments), segments: segments,
                    title: "Suggested correction")
    }

    private func handleTyping(_ context: TypingContext) {
        guard settings.passiveEnabled, !settings.isPaused, engine.isAvailable else { return }
        guard !settings.isDenied(context.bundleID) else { return }
        let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 3000,
              trimmed.rangeOfCharacter(from: .letters) != nil else {
            badge.hide()
            return
        }
        if let memo = lastTypingResult, memo.text == trimmed {
            updateBadge(context: context, trimmed: trimmed, corrected: memo.corrected)
            return
        }
        typingTask?.cancel()
        typingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let corrected = try await engine.perform(.proofread, on: trimmed)
                guard !Task.isCancelled else { return }
                lastTypingResult = (text: trimmed, corrected: corrected)
                updateBadge(context: context, trimmed: trimmed, corrected: corrected)
            } catch {
                NSLog("Quill passive check failed: \(error)")
            }
        }
    }

    private func updateBadge(context: TypingContext, trimmed: String, corrected: String) {
        guard !corrected.isEmpty, corrected != trimmed, let fieldFrame = context.fieldFrame else {
            badge.hide()
            return
        }
        let segments = WordDiff.suppressingPunctuationNormalization(WordDiff.diff(from: trimmed, to: corrected))
        let count = WordDiff.changeCount(segments)
        guard count > 0 else {
            badge.hide()
            return
        }
        badge.show(count: count, near: fieldFrame) { [weak self] in
            guard let self else { return }
            let anchor = CGRect(x: fieldFrame.maxX - 44, y: fieldFrame.minY + 8, width: 36, height: 26)
            let selection = TextSelection(
                text: context.text,
                element: context.element,
                pid: context.pid,
                bundleID: context.bundleID,
                appName: context.appName,
                anchorRect: anchor,
                wholeField: true
            )
            presentCard(for: selection, trimmed: trimmed, corrected: WordDiff.result(from: segments), segments: segments,
                        title: count == 1 ? "1 suggestion" : "\(count) suggestions")
        }
    }

    private func cleanModel(for selection: TextSelection, trimmed: String) -> CleanPillModel {
        CleanPillModel(
            onRephrase: { [weak self] in self?.performRewrite(.rephrase, selection: selection, trimmed: trimmed) },
            onImprove: { [weak self] in self?.performRewrite(.improve, selection: selection, trimmed: trimmed) }
        )
    }

    private func performRewrite(_ action: WritingAction, selection: TextSelection, trimmed: String) {
        checkTask?.cancel()
        panel.showChecking(near: selection.anchorRect, label: action.progressLabel)
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await engine.perform(action, on: trimmed)
                guard !Task.isCancelled else { return }
                guard !output.isEmpty, output != trimmed else {
                    panel.showClean(cleanModel(for: selection, trimmed: trimmed), near: selection.anchorRect)
                    return
                }
                let segments = WordDiff.suppressingPunctuationNormalization(WordDiff.diff(from: trimmed, to: output))
                let title = action == .rephrase ? "Rephrased" : "Improved"
                presentCard(for: selection, trimmed: trimmed, corrected: WordDiff.result(from: segments), segments: segments, title: title)
            } catch {
                NSLog("Quill \(action.progressLabel) failed: \(error)")
                panel.showError("Couldn't rewrite — try again", near: selection.anchorRect)
            }
        }
    }

    private func presentCard(
        for selection: TextSelection,
        trimmed: String,
        corrected: String,
        segments: [WordDiff.Segment],
        title: String
    ) {
        // Preserve any whitespace the selection carried around the trimmed text.
        let leading = String(selection.text.prefix(while: \.isWhitespace))
        let trailing = String(selection.text.reversed().prefix(while: \.isWhitespace).reversed())
        let replacement = leading + corrected + trailing

        let model = SuggestionCardModel(
            title: title,
            corrected: WordDiff.highlightedCorrected(segments),
            correctedText: corrected,
            engineLabel: "on-device",
            onAccept: { [weak self] in
                self?.watcher?.suppress(for: selection.wholeField ? 3.0 : 1.5)
                TextReplacer.replace(selection: selection, with: replacement)
                self?.panel.dismiss()
                self?.badge.hide()
            },
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(corrected, forType: .string)
                self?.panel.dismiss()
            },
            onDismiss: { [weak self] in
                self?.panel.dismiss()
            },
            onRephrase: { [weak self] in
                self?.performRewrite(.rephrase, selection: selection, trimmed: trimmed)
            },
            onImprove: { [weak self] in
                self?.performRewrite(.improve, selection: selection, trimmed: trimmed)
            }
        )
        panel.showSuggestion(model, near: selection.anchorRect)
    }
}
