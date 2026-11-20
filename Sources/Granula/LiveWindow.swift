import AppKit
import GranulaCore
import SwiftUI

/// The live transcript and its translation in a window of its own, over the call
/// (Zoom, Meet) and every other app, on every Space and next to full-screen apps.
/// Non-activating: clicking it never takes the focus from the call. Movable and
/// resizable; it opens where the owner left it.
@MainActor
final class LiveWindow {
    private var panel: NSPanel?
    private var delegate: Delegate?
    static let defaultSize = NSSize(width: 460, height: 560)
    static let minSize = NSSize(width: 340, height: 220)
    private static let autosaveName = "GranulaLive"

    var isShown: Bool { panel != nil }

    /// `onClose`: the owner closed it with the window's own button.
    func show(model: AppModel, onClose: @escaping () -> Void) {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Live transcript")
        panel.contentView = NSHostingView(rootView: LiveTranscriptView().environmentObject(model))
        panel.isFloatingPanel = true
        // Clicks on the pickers and buttons never take the keyboard from the call.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = Self.minSize
        let delegate = Delegate(onClose: onClose)
        panel.delegate = delegate
        // Where the owner left it last time; at first at the right edge of the screen.
        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main?.visibleFrame {
            let size = Self.defaultSize
            panel.setFrame(NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
        self.delegate = delegate
        Log.event("live_window.shown")
    }

    func hide() {
        guard let panel else { return }
        panel.saveFrame(usingName: Self.autosaveName)
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
        delegate = nil
        Log.event("live_window.hidden")
    }

    /// The window's content as a PNG (E2E checks); false when it is not on screen.
    @discardableResult
    func snapshot(to url: URL) -> Bool {
        guard let panel, panel.isVisible, let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }

    /// The close button turns the window off (the owner's choice) instead of closing it here.
    private final class Delegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { onClose() }
            return false
        }
    }
}
