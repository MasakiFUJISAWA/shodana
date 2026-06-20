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
                if browser.isEditingText {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else {
                    browser.cutSelection()
                }
            }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(!browser.isEditingText && browser.selectedIDs.isEmpty)

            Button("Copy") {
                if browser.isEditingText {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else {
                    browser.copySelection()
                }
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(!browser.isEditingText && browser.selectedIDs.isEmpty)

            Button("Paste") {
                if browser.isEditingText {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    browser.pasteIntoCurrentFolder()
                }
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
