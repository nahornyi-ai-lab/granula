import GranulaCore
import SwiftUI

/// One column, like Granola: «Главная», or a meeting opened over the whole window.
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let open = model.record(id: model.selection)
        Group {
            if let open {
                MeetingDetail(record: open).id(open.id)
            } else {
                HomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Top right of the window, like Granola. Not a toolbar item: with the window title
        // removed, macOS lines every toolbar item up on the left.
        .overlay(alignment: .topTrailing) {
            RecordButton().padding(.top, 10).padding(.trailing, 20)
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if open != nil {
                    Button { model.selection = nil } label: {
                        Label("Главная", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
        .toolbarBackground(Theme.background, for: .windowToolbar)
        .hidingWindowTitle()
    }
}

extension View {
    /// Granola shows no window title; macOS 14 keeps it.
    @ViewBuilder func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) } else { self }
    }
}

/// «Новая встреча» pill; during a recording «Остановить · 12:34».
struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 7) {
                Circle().fill(model.isRecording ? Color.red : Theme.accent).frame(width: 8, height: 8)
                if model.isRecording {
                    Text("Остановить · \(Transcript.clock(model.snapshot?.elapsed ?? 0))").monospacedDigit()
                } else {
                    Text("Новая встреча")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("⌥⌘R")
    }
}
