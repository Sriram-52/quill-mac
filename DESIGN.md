# Quill: Design Record

Decisions made during the initial design session (August 2026) and the
first day of real-world use.

## Product

- **Gap**: a selection-triggered correction card that runs fully on-device.
  Apple's Writing Tools is invoke-on-demand, per app, and not scriptable
  system-wide. Grammarly is cloud.
- **Interaction** (modeled on Grammarly Premium's selection card): select text
  in any app, a spinner pill appears instantly near the selection, then it
  morphs into the correction card when the correction differs, or briefly
  shows "Looks good" when it doesn't. Accept replaces in place.
- **Badge mode** (added after first use): while typing, the focused field is
  checked on pause and a red issue-count badge docks at the field's corner.
  This is the reliable alternative to inline underlines, which require
  per-character geometry that Electron apps and browsers report unreliably.
- Personal tool first, macOS only, no App Store, no sandbox.
- Scope: proofread (automatic) plus rephrase and improve (on demand).
- Out of scope: inline underlines at exact text positions, iOS, summarize and
  list generation (Writing Tools already does those), fallback engines for
  Macs without Apple Intelligence, Google Docs.

## Engine

Everything runs on Apple's Foundation Models framework, on-device. Cloud
providers were considered and deliberately cut: privacy is the point, and the
small model is good enough for corrections. The `WritingEngine` protocol
remains as a seam in case that ever changes.

## Architecture notes

- **Diffs are computed locally** (word-level LCS in `WordDiff`). The model
  returns corrected prose only; it is never trusted with character offsets.
- **Guided generation** (`@Generable RewriteOutput`) forces a single string
  result. Without it the raw model adds commentary and echoes text.
- **Punctuation normalization is filtered**: the small model converts em
  dashes to `--`, curly quotes to straight quotes, ellipses to `...`. Any
  delete/insert pair that differs only that way is folded back into the
  author's original text.
- **Selection watching**: `AXObserver` on the frontmost app for selection,
  focus, and value changes. 350 ms debounce for selections, 1.6 s for typing.
  Secure fields and non-editable elements are skipped. Chromium's caret
  movement doubles as the typing signal because it rarely emits value-changed.
- **Field policy** (`FieldPolicy.swift`) decides which focused elements are
  writing surfaces. Role alone was never enough: a browser address bar, a login
  box and a Gmail subject line are all `AXTextField`, so Quill used to pop up in
  all three. Four gates, modeled on Grammarly Desktop's `IntegrationOptions.json`
  and `IntegrationOptionsKeywordBlocklist.json`:
  1. **Surface class.** `AXTextArea` and contenteditable regions
     (`AXEditableAncestor`, or an unrecognised role with a settable value) are
     prose and pass by default. `AXTextField` and `AXComboBox` are single-line
     and are **off unless the app is opted in**. Search fields, labels, secure
     fields and read-only views never pass. This gate alone is what stops the
     address-bar popups.
  2. **Override rules**, bundled in `FieldPolicy.defaultRules` and extensible
     from `~/Library/Application Support/Quill/FieldPolicy.json`. Regex on
     bundle ID and element name, with `allowSingleLine`, `ignoreNameBlocklist`
     and `isEnabled`.
  3. **Name blocklist** over `AXTitle`, `AXDescription`, `AXPlaceholderValue`,
     `AXIdentifier` and `AXDOMIdentifier`. Credential and payment wording is
     refused everywhere; the noisier personal-info, login and email-header
     groups apply only to single-line fields, and the login group walks
     ancestors and the window title. Grammarly applies its whole list to every
     surface and pays for it with a long tail of per-app exemptions (Apple
     Notes' `Note[id=...]` matching `\bid\b`, ChatGPT's
     `mobile-composer-prompt` matching `mobile`); scoping the noisy half to
     single-line fields avoids most of that.
  4. **Per-app escape hatch**: "Check Single-Line Fields in <app>" in the menu
     bar, which is what makes gates 1 and 3 safe to be strict about.

  This is still the most app-dependent part of the code. `log show` prints the
  reason for every refusal.
- **Browsers and Electron**: `AXEnhancedUserInterface` and
  `AXManualAccessibility` are set on each watched app so Chromium enables its
  accessibility tree.
- **Anchoring**: the AX selection rect is trusted only when plausibly sized,
  on-screen, and near the mouse; otherwise the mouse position captured at
  selection time is used. Badges anchor to the field frame, which is far
  more reliable than range bounds.
- **Replacement**: `AXSelectedText` write when honored (verified by reading
  back), otherwise clipboard save, session-level ⌘V, clipboard restore.
  Badge mode swaps the whole field value, falling back to select-all + paste.
- **Panels** are non-activating borderless `NSPanel`s so the target app keeps
  focus.
- Everywhere by default with a denylist (seeded: Terminal, iTerm, Xcode,
  VS Code), plus pause and badge-mode toggles, persisted in UserDefaults.

## Reference projects

- theJayTea/WritingTools (GPL-3.0, reference only): hotkey + Accessibility pattern
- PhilipSchmid/textwarden (Apache-2.0): system-wide AX watching, Harper hybrid
- huytd/afm-grammar (BSD-3): minimal Foundation Models grammar CLI
- lukataylo/halen (MIT): Foundation Models first, tiered engines
- Known Accessibility pain: Electron needs a paste fallback; Google Docs is a dead zone.
