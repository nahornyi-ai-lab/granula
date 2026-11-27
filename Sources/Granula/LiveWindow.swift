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
    /// Narrower would clip the header: the language pickers and the lightbulb need up to
    /// about 372 pt (Ukrainian).
    static let minSize = NSSize(width: 390, height: 220)
    private static let autosaveName = "GranulaLive"
    /// Whether the saved frame includes the hints column.
    private static let savedWithHintsKey = "GranulaLiveHintsColumn"

    var isShown: Bool { panel != nil }

    /// The hints column's width: the window is this much wider while hints are on.
    static let hintsWidth: CGFloat = 300
    static let minWidthWithHints: CGFloat = minSize.width + 1 + hintsWidth

    private static func minSize(hints: Bool) -> NSSize {
        NSSize(width: hints ? minWidthWithHints : minSize.width, height: minSize.height)
    }

    /// `hints`: the hints column is on. `onClose`: the owner closed it with the window's own button.
    func show(model: AppModel, hints: Bool, onClose: @escaping () -> Void) {
        guard panel == nil else { return }
        let size = NSSize(width: Self.defaultSize.width + (hints ? Self.hintsWidth : 0), height: Self.defaultSize.height)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Live transcript")
        let host = NSHostingView(rootView: LiveTranscriptView().environmentObject(model))
        // The window's size is the owner's and the hints toggle's (setHints), not the content's.
        host.sizingOptions = []
        panel.contentView = host
        panel.isFloatingPanel = true
        // Clicks on the pickers and buttons never take the keyboard from the call.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let delegate = Delegate(onClose: onClose)
        panel.delegate = delegate
        // Where the owner left it last time; at first at the right edge of the screen. The
        // smaller minimum while restoring: AppKit would widen a narrower frame to the right.
        panel.minSize = Self.minSize(hints: false)
        if panel.setFrameUsingName(Self.autosaveName) {
            // Saved with the hints column and now without it, or the other way round: the
            // column comes or goes on the left, the right edge stays.
            var width = panel.frame.width
            if UserDefaults.standard.bool(forKey: Self.savedWithHintsKey) != hints {
                width += hints ? Self.hintsWidth : -Self.hintsWidth
            }
            width = max(width, Self.minSize(hints: hints).width)
            if width != panel.frame.width {
                panel.setFrame(Self.resized(panel.frame, width: width, screen: panel.screen ?? NSScreen.main),
                               display: false)
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: false)
        }
        panel.minSize = Self.minSize(hints: hints)
        UserDefaults.standard.set(hints, forKey: Self.savedWithHintsKey)
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

    /// Hints on or off during a recording: the window grows or shrinks by the column on its
    /// left side; its right edge stays.
    func setHints(_ on: Bool) {
        guard let panel else { return }
        let frame = panel.frame
        let width = on ? max(frame.width + Self.hintsWidth, Self.minWidthWithHints)
                       : max(frame.width - Self.hintsWidth, Self.minSize.width)
        panel.minSize = Self.minSize(hints: on)
        panel.setFrame(Self.resized(frame, width: width, screen: panel.screen), display: true)
        UserDefaults.standard.set(on, forKey: Self.savedWithHintsKey)
        Log.event("live_window.hints", on ? "on" : "off")
    }

    /// `frame` at `width` with its right edge kept, moved back inside the screen if that
    /// pushed it off (AppKit leaves a visible window where it is put).
    private static func resized(_ frame: NSRect, width: CGFloat, screen: NSScreen?) -> NSRect {
        var frame = frame
        frame.origin.x = frame.maxX - width
        frame.size.width = width
        guard let visible = screen?.visibleFrame else { return frame }
        if frame.width > visible.width {
            frame.size.width = max(visible.width, minSize.width)
            frame.origin.x = visible.minX
        } else if frame.minX < visible.minX {
            frame.origin.x = visible.minX
        } else if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width
        }
        return frame
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
