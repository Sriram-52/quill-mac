import AppKit
import SwiftUI

struct CleanPillModel {
    let onRephrase: () -> Void
    let onImprove: () -> Void
}

enum PanelState {
    case checking(String)
    case clean(CleanPillModel)
    case error(String)
    case suggestion(SuggestionCardModel)
}

struct PanelContentView: View {
    let state: PanelState

    var body: some View {
        Group {
            switch state {
            case .checking(let label):
                pill {
                    ProgressView()
                        .controlSize(.small)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .clean(let model):
                pill {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Looks good")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 12)
                    Button("Rephrase", action: model.onRephrase)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Button("Improve", action: model.onImprove)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            case .error(let message):
                pill {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .suggestion(let model):
                SuggestionCardView(model: model)
            }
        }
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// Floating, non-activating panel near the selection. Shows a spinner the
/// moment a check starts, then morphs into the card, a "Looks good" pill
/// (with Rephrase/Improve still available), or a brief error pill.
/// Never steals focus from the target app.
@MainActor
final class SuggestionPanelController {
    private var panel: NSPanel?
    private var anchor: CGRect = .zero
    private var autoDismissTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    func showChecking(near anchor: CGRect, label: String = "Checking…") {
        self.anchor = anchor
        render(.checking(label))
    }

    func showClean(_ model: CleanPillModel, near anchor: CGRect? = nil) {
        if let anchor { self.anchor = anchor }
        render(.clean(model))
        autoDismiss(after: 3.5)
    }

    func showError(_ message: String, near anchor: CGRect? = nil) {
        if let anchor { self.anchor = anchor }
        render(.error(message))
        autoDismiss(after: 2.5)
    }

    func showSuggestion(_ model: SuggestionCardModel, near anchor: CGRect? = nil) {
        if let anchor { self.anchor = anchor }
        render(.suggestion(model))
    }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func autoDismiss(after seconds: TimeInterval) {
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func render(_ state: PanelState) {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        let host = NSHostingView(rootView: PanelContentView(state: state))
        host.setFrameSize(host.fittingSize)
        let size = host.frame.size

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func origin(for size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return CGPoint(x: anchor.minX, y: anchor.minY - size.height - 10)
        }
        var x = anchor.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        var y = anchor.minY - size.height - 10
        if y < visible.minY + 8 {
            y = min(anchor.maxY + 10, visible.maxY - size.height - 8)
        }
        return CGPoint(x: x, y: y)
    }
}
