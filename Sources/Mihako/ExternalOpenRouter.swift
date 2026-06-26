import AppKit
import Foundation

@MainActor
enum ExternalOpenRouter {
    private static var pendingURLs: [URL] = []
    private static var openWindow: (() -> Void)?

    static func configure(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
    }

    static func enqueue(_ urls: [URL]) {
        let destinations = urls.compactMap(destinationURL)

        guard !destinations.isEmpty else {
            return
        }

        pendingURLs.append(contentsOf: destinations)

        if let openWindow {
            for _ in destinations {
                openWindow()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func consumeNextPendingURL() -> URL? {
        guard !pendingURLs.isEmpty else {
            return nil
        }

        return pendingURLs.removeFirst()
    }

    private static func destinationURL(from url: URL) -> URL? {
        if url.isFileURL {
            return url
        }

        guard url.scheme?.lowercased() == "mihako",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let host = components.host?.lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

        guard host == "open" || path == "open" || host == nil else {
            return nil
        }

        let queryItems = components.queryItems ?? []

        if let rawURL = queryItems.first(where: { $0.name == "url" })?.value,
           let destination = URL(string: rawURL) {
            return destination
        }

        if let rawPath = queryItems.first(where: { $0.name == "path" })?.value {
            return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        }

        return nil
    }
}
