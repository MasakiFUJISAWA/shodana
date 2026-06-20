import Foundation

enum FileSortColumn: String, CaseIterable {
    case name
    case modifiedAt
    case size
    case kind
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: String { rawValue }
}

enum FileClipboardMode {
    case copy
    case cut
}

struct FileClipboardOperation {
    let mode: FileClipboardMode
    let urls: [URL]
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
    let currentName: String
}

struct SidebarLocation: Identifiable, Hashable {
    var id: URL { url }

    let title: String
    let systemImageName: String
    let url: URL
    let canRemoveFromFavorites: Bool

    init(
        title: String,
        systemImageName: String,
        url: URL,
        canRemoveFromFavorites: Bool = false
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.url = url
        self.canRemoveFromFavorites = canRemoveFromFavorites
    }
}

struct SidebarSection: Identifiable, Hashable {
    var id: String { title }

    let title: String
    let locations: [SidebarLocation]
}

struct Breadcrumb: Identifiable, Hashable {
    var id: String { url.path }

    let title: String
    let url: URL
}

struct FileItem: Identifiable, Hashable {
    var id: URL { url }

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64?
    let modifiedAt: Date?
    let kind: String
    let isHidden: Bool

    var canNavigateInto: Bool {
        isDirectory && !isPackage
    }

    var displayName: String {
        name.isEmpty ? url.lastPathComponent : name
    }

    var systemImageName: String {
        if isPackage {
            return "shippingbox"
        }

        if isDirectory {
            return "folder"
        }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "webp":
            return "photo"
        case "mov", "mp4", "m4v", "avi":
            return "film"
        case "mp3", "m4a", "wav", "aiff":
            return "music.note"
        case "zip", "gz", "tar", "rar", "7z":
            return "archivebox"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "html", "css", "json", "xml", "yaml", "yml":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    var formattedSize: String {
        guard !isDirectory, let size else {
            return ""
        }

        return size.formatted(.byteCount(style: .file))
    }

    var formattedModifiedAt: String {
        guard let modifiedAt else {
            return ""
        }

        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func load(from url: URL) throws -> FileItem {
        let resourceValues = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .localizedNameKey
        ])

        let isDirectory = resourceValues.isDirectory ?? false
        let size = resourceValues.fileSize.map(Int64.init)
            ?? resourceValues.totalFileAllocatedSize.map(Int64.init)

        return FileItem(
            url: url,
            name: resourceValues.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: resourceValues.isPackage ?? false,
            size: size,
            modifiedAt: resourceValues.contentModificationDate,
            kind: resourceValues.localizedTypeDescription ?? (isDirectory ? "Folder" : "File"),
            isHidden: resourceValues.isHidden ?? false
        )
    }
}
