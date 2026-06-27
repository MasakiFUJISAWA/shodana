import Darwin
import Foundation

enum CloudFileStatusDetector {
    static func isCloudManaged(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }

        let path = url.standardizedFileURL.path
        let lowercasedPath = path.lowercased()

        if lowercasedPath.contains("/library/cloudstorage/") ||
            lowercasedPath.contains("/library/mobile documents/") {
            return true
        }

        let components = url.pathComponents.map { $0.lowercased() }
        return components.contains { component in
            component.contains("onedrive") ||
                component.contains("sharepoint") ||
                component.contains("google drive") ||
                component.contains("googledrive") ||
                component.contains("icloud drive")
        }
    }

    static func status(for url: URL) -> CloudFileStatus? {
        guard isCloudManaged(url) else {
            return nil
        }

        if rawResourceValue(for: "NSURLUbiquitousItemDownloadingErrorKey", at: url) != nil ||
            rawResourceValue(for: "NSURLUbiquitousItemUploadingErrorKey", at: url) != nil {
            return .error
        }

        if boolResourceValue(for: "NSURLUbiquitousItemIsDownloadingKey", at: url) == true ||
            boolResourceValue(for: "NSURLUbiquitousItemIsUploadingKey", at: url) == true {
            return .syncing
        }

        if let downloadingStatus = rawResourceValue(
            for: "NSURLUbiquitousItemDownloadingStatusKey",
            at: url
        ) as? String {
            let lowercasedStatus = downloadingStatus.lowercased()

            if lowercasedStatus.contains("notdownloaded") {
                return .cloudOnly
            }

            if lowercasedStatus.contains("current") || lowercasedStatus.contains("downloaded") {
                return .synced
            }
        }

        if boolResourceValue(for: "NSURLUbiquitousItemIsDownloadedKey", at: url) == false {
            return .cloudOnly
        }

        let extendedAttributes = extendedAttributeNames(for: url)
        let lowercasedAttributes = extendedAttributes.map { $0.lowercased() }

        if lowercasedAttributes.contains(where: { $0.contains("error") }) {
            return .error
        }

        if lowercasedAttributes.contains(where: { $0.contains("sync") || $0.contains("progress") }) {
            return .syncing
        }

        if lowercasedAttributes.contains(where: { $0.contains("pinned") || $0.contains("materialized") }) {
            return .pinned
        }

        if likelyCloudOnlyPlaceholder(url) {
            return .cloudOnly
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return .synced
        }

        return .unknown
    }

    private static func likelyCloudOnlyPlaceholder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]),
            values.isDirectory != true,
            let logicalSize = values.fileSize,
            logicalSize > 0 else {
            return false
        }

        let allocatedSize = values.fileAllocatedSize ?? values.totalFileAllocatedSize ?? 0
        return allocatedSize == 0
    }

    private static func rawResourceValue(for keyName: String, at url: URL) -> Any? {
        var value: AnyObject?

        do {
            try (url as NSURL).getResourceValue(
                &value,
                forKey: URLResourceKey(rawValue: keyName)
            )
            return value
        } catch {
            return nil
        }
    }

    private static func boolResourceValue(for keyName: String, at url: URL) -> Bool? {
        rawResourceValue(for: keyName, at: url) as? Bool
    }

    private static func extendedAttributeNames(for url: URL) -> [String] {
        let length = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return 0
            }

            return listxattr(path, nil, 0, 0)
        }

        guard length > 0 else {
            return []
        }

        var data = [CChar](repeating: 0, count: length)
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return 0
            }

            return listxattr(path, &data, length, 0)
        }

        guard result > 0 else {
            return []
        }

        return data
            .split(separator: 0)
            .compactMap { buffer in
                String(bytes: buffer.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            }
    }
}
