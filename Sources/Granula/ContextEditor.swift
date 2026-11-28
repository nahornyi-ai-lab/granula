import AppKit
import GranulaCore
import SwiftUI
import UniformTypeIdentifiers

/// A meeting's context: free text plus the text of files added with Add file… or dropped onto
/// the field. Saved half a second after typing stops, like the notes.
struct ContextEditor: View {
    @Binding var text: String
    let save: (String) -> Void
    var height: CGFloat = 180
    /// What was last saved as far as this editor knows; nil until it appears.
    @State private var savedText: String?
    @State private var pendingSave: DispatchWorkItem?
    /// Files that gave no text.
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ContextTextView(text: $text, onFiles: add)
                if text.isEmpty {
                    Text("What the meeting is about: the agenda, what to discuss, a résumé. Hints and the summary use it.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("Add file…", action: pick)
                Text("PDF, Word, RTF, OpenDocument, text, Markdown or HTML; or drop files onto the field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { savedText = text }
        .onChange(of: text) { _, new in
            guard let savedText else { return }
            // The last text always wins: an edit undone within half a second cancels its save.
            pendingSave?.cancel()
            pendingSave = nil
            guard new != savedText else { return }
            let work = DispatchWorkItem {
                self.savedText = new
                pendingSave = nil
                save(new)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        .onDisappear { flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
        // A recording that starts now reads the context from disk.
        .onReceive(NotificationCenter.default.publisher(for: .flushContextEdits)) { _ in flush() }
    }

    /// Saves typing that the 0.5 s autosave has not written yet.
    private func flush() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        savedText = text
        save(text)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ContextImport.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Each file's text goes at the end, under its name; a file without text adds nothing.
    private func add(_ urls: [URL]) {
        var new = text
        var empty: [String] = []
        for url in urls {
            if let fileText = ContextImport.text(from: url) {
                new = ContextImport.appending(fileText, named: url.lastPathComponent, to: new)
            } else {
                empty.append(url.lastPathComponent)
            }
        }
        Log.event("context.files", "added=\(urls.count - empty.count) empty=\(empty.count)")
        message = empty.isEmpty ? nil
            : String(localized: "No text in \(empty.joined(separator: ", ")) — a scanned PDF? Export it with text or paste the text.")
        text = new
    }
}

/// A plain-text editor whose dropped files become their text instead of a path.
private struct ContextTextView: NSViewRepresentable {
    @Binding var text: String
    let onFiles: @MainActor ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // TextKit 1: there undo and redo post textDidChange, so they reach the binding.
        let view = DropTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        context.coordinator.lastText = text
        view.delegate = context.coordinator
        view.onFiles = onFiles
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = scroll.documentView as? DropTextView else { return }
        view.onFiles = onFiles
        // Only a change made outside the view (a file added) is put in: typing is already there,
        // and a composition in progress (a dead key, an input method) is not in the binding yet.
        guard text != coordinator.lastText, !view.hasMarkedText() else { return }
        coordinator.lastText = text
        // As one undoable edit: ⌘Z takes the file out and leaves the typing.
        let all = NSRange(location: 0, length: (view.string as NSString).length)
        view.breakUndoCoalescing()
        if view.shouldChangeText(in: all, replacementString: text) {
            view.textStorage?.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: view.typingAttributes))
            view.didChangeText()
        }
        view.breakUndoCoalescing()
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.scrollToEndOfDocument(nil)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ContextTextView
        /// The text as the view last had it: the binding differs from it only after a change from outside.
        var lastText = ""
        init(_ parent: ContextTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            lastText = view.string
            if parent.text != view.string { parent.text = view.string }
        }
    }
}

extension Notification.Name {
    /// Context editors save typing the autosave has not written yet (a recording is starting).
    static let flushContextEdits = Notification.Name("GranulaFlushContextEdits")
}

/// NSTextView would insert a dropped file's path; here the files go to `onFiles`.
private final class DropTextView: NSTextView {
    var onFiles: (@MainActor ([URL]) -> Void)?

    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types.contains(.fileURL) ? types : types + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        files(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty, let onFiles else { return super.performDragOperation(sender) }
        onFiles(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, !files(sender).isEmpty { return }
        super.concludeDragOperation(sender)
    }
}
