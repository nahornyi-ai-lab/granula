import AppKit
import GranulaCore
import SwiftUI

/// Floating "Звонок в Telegram — записать?" panel in the top-right corner,
/// also used for the calendar reminder. Non-activating: it never steals focus.
@MainActor
final class CallPromptPanel {
    private var panel: NSPanel?
    private var shownFamily: String?

    func show(app: CallDetector.CallApp, onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        show(title: String(localized: "Звонок в \(app.name)"), onRecord: onRecord, onDismiss: onDismiss)
        shownFamily = app.family
    }

    /// Any prompt: a call («Звонок в Zoom») or a calendar meeting («Через 1 мин: …»).
    func show(title: String, subtitle: String = String(localized: "Записать встречу?"),
              onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()
        let view = CallPromptView(title: title, subtitle: subtitle, onRecord: onRecord, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - hosting.fittingSize.width - 16,
                                         y: screen.maxY - hosting.fittingSize.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        shownFamily = nil
    }

    /// Hides the panel only if it is about this call app (the call has ended).
    func hide(callFamily: String) {
        if shownFamily == callFamily { hide() }
    }
}

private struct CallPromptView: View {
    let title: String
    let subtitle: String
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(2)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Не сейчас", action: onDismiss)
            Button("Записать", action: onRecord)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(14)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}
