import AppKit
import SwiftUI

@main
struct MyFinderApp: App {
    @StateObject private var browser = FileBrowserViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(browser)
        }
        .commands {
            BrowserCommands(browser: browser)
        }
    }
}

@MainActor
struct BrowserCommands: Commands {
    @ObservedObject var browser: FileBrowserViewModel

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                browser.handleFileCutShortcut()
            }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(!browser.isTextInputActive && !browser.canCutOrCopySelection)

            Button("Copy") {
                browser.handleFileCopyShortcut()
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(!browser.isTextInputActive && !browser.canCutOrCopySelection)

            Button("Paste") {
                browser.handleFilePasteShortcut()
            }
            .keyboardShortcut("v", modifiers: [.command])
        }

        CommandGroup(after: .newItem) {
            Button("New Folder") {
                browser.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Files") {
            Button("Open") {
                browser.openSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(browser.selectedIDs.isEmpty)

            Button("Rename") {
                browser.beginRenameSelected()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(browser.selectedIDs.count != 1)

            Divider()

            Button("Move to Trash") {
                browser.trashSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(browser.selectedIDs.isEmpty)
        }
    }
}
