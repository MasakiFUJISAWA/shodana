import AppKit
import SwiftUI

@main
struct MihakoApp: App {
    @NSApplicationDelegateAdaptor(MihakoApplicationDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)

        if let iconImage = AppIconLoader.load() {
            NSApplication.shared.applicationIconImage = iconImage
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Mihako", id: "browser") {
            BrowserWindowView()
        }
        .commands {
            BrowserCommands()
        }
    }
}

struct BrowserWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var browser = FileBrowserViewModel()

    var body: some View {
        ContentView()
            .environmentObject(browser)
            .focusedSceneValue(\.fileBrowser, browser)
            .onAppear {
                MihakoApplicationDelegate.openNewWindow = {
                    openWindow(id: "browser")
                }
            }
    }
}

@MainActor
final class MihakoApplicationDelegate: NSObject, NSApplicationDelegate {
    static var openNewWindow: (() -> Void)?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "New Window",
            action: #selector(openNewWindowFromDock(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openNewWindowFromDock(_ sender: Any?) {
        Self.openNewWindow?()
    }
}

struct FileBrowserFocusedValueKey: FocusedValueKey {
    typealias Value = FileBrowserViewModel
}

extension FocusedValues {
    var fileBrowser: FileBrowserViewModel? {
        get { self[FileBrowserFocusedValueKey.self] }
        set { self[FileBrowserFocusedValueKey.self] = newValue }
    }
}

enum AppIconLoader {
    static func load() -> NSImage? {
        let candidateURLs = [
            Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }
}

@MainActor
struct BrowserCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.fileBrowser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "browser")
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Folder") {
                browser?.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(browser == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                browser?.handleFileCutShortcut()
            }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(browser == nil)

            Button("Copy") {
                browser?.handleFileCopyShortcut()
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(browser == nil)

            Button("Paste") {
                browser?.handleFilePasteShortcut()
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(browser == nil)
        }

        CommandMenu("Files") {
            Button("Open") {
                browser?.openSelected()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(browser?.selectedIDs.isEmpty ?? true)

            Button("Rename") {
                browser?.beginRenameSelected()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled((browser?.selectedIDs.count ?? 0) != 1)

            Divider()

            Button("Move to Trash") {
                browser?.trashSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(browser?.selectedIDs.isEmpty ?? true)
        }
    }
}
