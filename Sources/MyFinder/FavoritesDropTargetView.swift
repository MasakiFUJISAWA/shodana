import AppKit
import SwiftUI

struct FavoritesDropTargetView: NSViewRepresentable {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> FavoritesDropTargetNSView {
        let view = FavoritesDropTargetNSView()
        view.onTargetedChanged = { isTargeted in
            context.coordinator.isTargeted.wrappedValue = isTargeted
        }
        view.onDropURLs = { urls in
            for url in urls {
                context.coordinator.browser?.addFavoriteFolder(url)
            }
        }
        return view
    }

    func updateNSView(_ view: FavoritesDropTargetNSView, context: Context) {
        context.coordinator.browser = browser
        context.coordinator.isTargeted = $isTargeted
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser, isTargeted: $isTargeted)
    }

    final class Coordinator {
        var browser: FileBrowserViewModel?
        var isTargeted: Binding<Bool>

        init(browser: FileBrowserViewModel, isTargeted: Binding<Bool>) {
            self.browser = browser
            self.isTargeted = isTargeted
        }
    }
}

final class FavoritesDropTargetNSView: NSView {
    var onTargetedChanged: ((Bool) -> Void)?
    var onDropURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard)
        onTargetedChanged?(!urls.isEmpty)
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        onTargetedChanged?(false)
        onDropURLs?(urls)
        return !urls.isEmpty
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var droppedURLs: [URL] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] {
            droppedURLs.append(contentsOf: objects.map { $0 as URL })
        }

        if let filenames = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String] {
            droppedURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }

        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .string] {
            if let value = pasteboard.string(forType: type) {
                droppedURLs.append(contentsOf: urls(from: value))
            }
        }

        var seenPaths: Set<String> = []
        return droppedURLs.filter { url in
            let path = url.standardizedFileURL.path
            return seenPaths.insert(path).inserted
        }
    }

    private func urls(from value: String) -> [URL] {
        value
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { rawValue -> URL? in
                let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmedValue.isEmpty else {
                    return nil
                }

                if let url = URL(string: trimmedValue), url.isFileURL {
                    return url
                }

                return URL(fileURLWithPath: trimmedValue, isDirectory: true)
            }
    }
}
