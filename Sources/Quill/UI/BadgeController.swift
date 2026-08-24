import AppKit
import SwiftUI

struct BadgeView: View {
    let count: Int
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 14)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(red: 0.92, green: 0.30, blue: 0.29)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Quill found \(count) issue\(count == 1 ? "" : "s") — click to review")
    }
}

/// Small red issue-count badge docked at the bottom-right corner of the
/// focused text field. Non-activating; clicking it opens the suggestion card.
@MainActor
final class BadgeController {
    private var panel: NSPanel?

    func show(count: Int, near fieldFrame: CGRect, onClick: @escaping () -> Void) {
        let host = NSHostingView(rootView: BadgeView(count: count, onClick: onClick))
        host.setFrameSize(host.fittingSize)
        let size = host.frame.size

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host

        var x = fieldFrame.maxX - size.width - 10
        var y = fieldFrame.minY + 10
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldFrame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
            y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
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
}
