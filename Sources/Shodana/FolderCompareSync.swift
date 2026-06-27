import AppKit
import CryptoKit
import Foundation
import SwiftUI

enum FolderCompareStatus: String, CaseIterable, Identifiable {
    case same
    case leftOnly
    case rightOnly
    case differentSize
    case differentModified
    case differentContent
    case typeDifference

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .same:
            return "Same"
        case .leftOnly:
            return "Left Only"
        case .rightOnly:
            return "Right Only"
        case .differentSize:
            return "Different Size"
        case .differentModified:
            return "Modified Time Difference"
        case .differentContent:
            return "Content Difference"
        case .typeDifference:
            return "Type Difference"
        }
    }

    var color: Color {
        switch self {
        case .same:
            return .green
        case .differentSize, .differentModified:
            return .yellow
        case .differentContent, .typeDifference:
            return .red
        case .leftOnly, .rightOnly:
            return .secondary
        }
    }
}

enum FolderCompareFilter: String, CaseIterable, Identifiable {
    case all
    case differences
    case leftOnly
    case rightOnly
    case contentDifference
    case modifiedDifference

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all:
            return "All"
        case .differences:
            return "Differences Only"
        case .leftOnly:
            return "Left Only"
        case .rightOnly:
            return "Right Only"
        case .contentDifference:
            return "Content Difference"
        case .modifiedDifference:
            return "Modified Time Difference"
        }
    }

    func includes(_ entry: FolderCompareEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .differences:
            return entry.status != .same
        case .leftOnly:
            return entry.status == .leftOnly
        case .rightOnly:
            return entry.status == .rightOnly
        case .contentDifference:
            return entry.status == .differentContent || entry.status == .typeDifference
        case .modifiedDifference:
            return entry.status == .differentModified
        }
    }
}

enum FolderSyncMode: String, CaseIterable, Identifiable {
    case mirror
    case update
    case twoWay
    case backup

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .mirror:
            return "Mirror"
        case .update:
            return "Update"
        case .twoWay:
            return "Two-Way"
        case .backup:
            return "Backup"
        }
    }
}

enum FolderSyncActionKind: String {
    case copyLeftToRight
    case copyRightToLeft
    case deleteRight
    case backupLeftToRight
    case conflict
    case unchanged

    var titleKey: String {
        switch self {
        case .copyLeftToRight:
            return "Copy Left to Right"
        case .copyRightToLeft:
            return "Copy Right to Left"
        case .deleteRight:
            return "Delete Right"
        case .backupLeftToRight:
            return "Backup Left to Right"
        case .conflict:
            return "Conflict"
        case .unchanged:
            return "Unchanged"
        }
    }
}

struct FolderSnapshotEntry: Hashable, Sendable {
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64?
    let modifiedAt: Date?
    let contentHash: String?
}

struct FolderCompareEntry: Identifiable, Hashable {
    var id: String { relativePath }

    let relativePath: String
    let left: FolderSnapshotEntry?
    let right: FolderSnapshotEntry?
    let status: FolderCompareStatus

    var displayPath: String {
        relativePath.isEmpty ? "." : relativePath
    }

    var canShowDetail: Bool {
        let candidates = [left, right].compactMap { $0 }
        return !candidates.isEmpty && candidates.allSatisfy { !$0.isDirectory }
    }
}

struct FolderSyncPlanItem: Identifiable, Hashable {
    let id = UUID()
    let kind: FolderSyncActionKind
    let relativePath: String
    let source: FolderSnapshotEntry?
    let destination: FolderSnapshotEntry?
    let backupRelativePath: String?

    var displayPath: String {
        relativePath.isEmpty ? "." : relativePath
    }
}

struct FolderSyncLogRow: Identifiable {
    let id = UUID()
    let timestamp: Date
    let action: String
    let path: String
    let result: String
    let message: String
}

enum FolderCompareSyncError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedSync(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid folder URL: \(value)"
        case .unsupportedSync(let message):
            return message
        }
    }
}

@MainActor
final class FolderCompareSyncViewModel: ObservableObject {
    @Published var leftText: String
    @Published var rightText: String
    @Published var compareEntries: [FolderCompareEntry] = []
    @Published var planItems: [FolderSyncPlanItem] = []
    @Published private var allPlanItems: [FolderSyncPlanItem] = []
    @Published private var syncCandidatePaths = Set<String>()
    @Published private var selectedSyncPaths = Set<String>()
    @Published var logRows: [FolderSyncLogRow] = []
    @Published var filter: FolderCompareFilter = .all
    @Published var syncMode: FolderSyncMode = .update {
        didSet {
            rebuildPlan(selectAllByDefault: true)
        }
    }
    @Published var useContentHash = true
    @Published var respectIgnoreRules = true
    @Published var dryRun = true
    @Published var confirmLargeDeletion = false
    @Published private(set) var isComparing = false
    @Published private(set) var isSyncing = false
    @Published private(set) var progressText = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLogURL: URL?

    private let showHiddenFiles: Bool
    private var leftURL: URL?
    private var rightURL: URL?
    private let largeDeletionThreshold = 10

    init(leftInitialURL: URL, rightInitialURL: URL, showHiddenFiles: Bool) {
        leftText = Self.displayString(for: leftInitialURL)
        rightText = Self.displayString(for: rightInitialURL)
        self.showHiddenFiles = showHiddenFiles
    }

    var filteredEntries: [FolderCompareEntry] {
        compareEntries.filter { filter.includes($0) }
    }

    var hasComparison: Bool {
        !compareEntries.isEmpty
    }

    var hasSyncCandidates: Bool {
        !allPlanItems.isEmpty
    }

    var selectedSyncCount: Int {
        planItems.count
    }

    var syncCandidateCount: Int {
        allPlanItems.count
    }

    var areAllSyncCandidatesSelected: Bool {
        hasSyncCandidates && selectedSyncPaths.isSuperset(of: allSyncCandidatePaths)
    }

    var deleteCount: Int {
        planItems.filter { $0.kind == .deleteRight }.count
    }

    var conflictCount: Int {
        planItems.filter { $0.kind == .conflict }.count
    }

    var requiresLargeDeletionConfirmation: Bool {
        syncMode == .mirror && deleteCount >= largeDeletionThreshold
    }

    var canRunSync: Bool {
        hasComparison
            && !isComparing
            && !isSyncing
            && !planItems.isEmpty
            && conflictCount == 0
            && (!requiresLargeDeletionConfirmation || confirmLargeDeletion)
    }

    var summaryText: String {
        guard hasComparison else {
            return L10n.string("No comparison yet.")
        }

        let sameCount = compareEntries.filter { $0.status == .same }.count
        let differenceCount = compareEntries.count - sameCount
        return String(
            format: L10n.string("folder.compare.summary"),
            compareEntries.count,
            sameCount,
            differenceCount
        )
    }

    var planSummaryText: String {
        guard !planItems.isEmpty else {
            return L10n.string("No sync actions.")
        }

        let copyCount = planItems.filter {
            $0.kind == .copyLeftToRight || $0.kind == .copyRightToLeft || $0.kind == .backupLeftToRight
        }.count
        return String(
            format: L10n.string("folder.sync.summary"),
            copyCount,
            deleteCount,
            conflictCount
        )
    }

    func clearError() {
        errorMessage = nil
    }

    func compare() {
        guard !isComparing else {
            return
        }

        guard let leftURL = Self.url(from: leftText) else {
            errorMessage = L10n.string("Invalid left folder.")
            return
        }

        guard let rightURL = Self.url(from: rightText) else {
            errorMessage = L10n.string("Invalid right folder.")
            return
        }

        self.leftURL = leftURL
        self.rightURL = rightURL
        compareEntries = []
        planItems = []
        allPlanItems = []
        syncCandidatePaths = []
        selectedSyncPaths = []
        logRows = []
        isComparing = true
        progressText = L10n.string("Scanning folders...")

        Task {
            do {
                async let leftSnapshot = FolderCompareSyncEngine.scan(
                    rootURL: leftURL,
                    showHiddenFiles: showHiddenFiles,
                    respectIgnoreRules: respectIgnoreRules,
                    useContentHash: useContentHash
                )
                async let rightSnapshot = FolderCompareSyncEngine.scan(
                    rootURL: rightURL,
                    showHiddenFiles: showHiddenFiles,
                    respectIgnoreRules: respectIgnoreRules,
                    useContentHash: useContentHash
                )

                let entries = try await FolderCompareSyncEngine.compare(
                    left: leftSnapshot,
                    right: rightSnapshot
                )

                await MainActor.run {
                    self.compareEntries = entries
                    self.isComparing = false
                    self.progressText = ""
                    self.confirmLargeDeletion = false
                    self.rebuildPlan(selectAllByDefault: true)
                }
            } catch {
                await MainActor.run {
                    self.isComparing = false
                    self.progressText = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func isSyncCandidate(_ entry: FolderCompareEntry) -> Bool {
        allSyncCandidatePaths.contains(entry.relativePath)
    }

    func isSyncSelected(_ entry: FolderCompareEntry) -> Bool {
        isSyncCandidate(entry) && selectedSyncPaths.contains(entry.relativePath)
    }

    func setSyncSelected(_ isSelected: Bool, for entry: FolderCompareEntry) {
        guard isSyncCandidate(entry) else {
            return
        }

        let affectedPaths = syncCandidatePaths(coveredBy: entry)

        if isSelected {
            selectedSyncPaths.formUnion(affectedPaths)
        } else {
            selectedSyncPaths.subtract(affectedPaths)
            removeAncestorDirectorySelections(for: entry.relativePath)
        }

        rebuildPlan()
    }

    func selectAllSyncCandidates() {
        selectedSyncPaths = allSyncCandidatePaths
        rebuildPlan()
    }

    func clearAllSyncCandidates() {
        selectedSyncPaths.subtract(allSyncCandidatePaths)
        rebuildPlan()
    }

    func rebuildPlan(selectAllByDefault: Bool = false) {
        guard let leftURL, let rightURL else {
            allPlanItems = []
            syncCandidatePaths = []
            planItems = []
            return
        }

        let plannedItems = FolderCompareSyncEngine.plan(
            entries: compareEntries,
            mode: syncMode,
            leftRootURL: leftURL,
            rightRootURL: rightURL
        )
        let plannedPaths = Set(plannedItems.map(\.relativePath))

        allPlanItems = plannedItems
        syncCandidatePaths = plannedPaths

        if selectAllByDefault {
            selectedSyncPaths = plannedPaths
        } else {
            selectedSyncPaths = selectedSyncPaths.intersection(plannedPaths)
        }

        planItems = filteredPlanItems(from: plannedItems)
        confirmLargeDeletion = false
    }

    func runSync() {
        guard canRunSync,
              let leftURL,
              let rightURL else {
            return
        }

        isSyncing = true
        logRows = []
        lastLogURL = nil
        progressText = dryRun ? L10n.string("Dry Run") : L10n.string("Syncing...")

        Task {
            let result = await FolderCompareSyncEngine.sync(
                planItems: planItems,
                mode: syncMode,
                dryRun: dryRun,
                leftRootURL: leftURL,
                rightRootURL: rightURL
            ) { completed, total in
                await MainActor.run {
                    self.progressText = "\(completed) / \(total)"
                }
            }

            await MainActor.run {
                self.isSyncing = false
                self.progressText = ""
                self.logRows = result.rows
                self.lastLogURL = result.logURL

                if !self.dryRun {
                    self.compare()
                }
            }
        }
    }

    private static func displayString(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) {
            return SFTPClient.displayString(for: url)
        }

        if S3Client.isS3URL(url) {
            return S3Client.displayString(for: url)
        }

        return url.path
    }

    private static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("sftp://") || lowercased.hasPrefix("s3://") {
            return URL(string: trimmed)
        }

        if lowercased.hasPrefix("file://") {
            return URL(string: trimmed)
        }

        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    private var allSyncCandidatePaths: Set<String> {
        syncCandidatePaths
    }

    private func filteredPlanItems(from plannedItems: [FolderSyncPlanItem]) -> [FolderSyncPlanItem] {
        plannedItems.filter { item in
            guard selectedSyncPaths.contains(item.relativePath) else {
                return false
            }

            guard item.kind == .deleteRight,
                  item.destination?.isDirectory == true else {
                return true
            }

            let descendantDeletePaths = plannedItems
                .filter { candidate in
                    candidate.kind == .deleteRight
                        && candidate.relativePath.isDescendant(of: item.relativePath)
                }
                .map(\.relativePath)

            return descendantDeletePaths.allSatisfy { selectedSyncPaths.contains($0) }
        }
    }

    private func syncCandidatePaths(coveredBy entry: FolderCompareEntry) -> Set<String> {
        guard entry.left?.isDirectory == true || entry.right?.isDirectory == true else {
            return [entry.relativePath]
        }

        return allSyncCandidatePaths.filter { path in
            path == entry.relativePath || path.isDescendant(of: entry.relativePath)
        }
    }

    private func removeAncestorDirectorySelections(for relativePath: String) {
        for item in allPlanItems where item.source?.isDirectory == true || item.destination?.isDirectory == true {
            if relativePath.isDescendant(of: item.relativePath) {
                selectedSyncPaths.remove(item.relativePath)
            }
        }
    }
}

enum FolderCompareSyncEngine {
    struct SyncResult {
        let rows: [FolderSyncLogRow]
        let logURL: URL?
    }

    static func scan(
        rootURL: URL,
        showHiddenFiles: Bool,
        respectIgnoreRules: Bool,
        useContentHash: Bool
    ) async throws -> [String: FolderSnapshotEntry] {
        let rootURL = try await resolvedRootURL(rootURL)
        let ignoreMatcher = try IgnoreMatcher(rootURL: rootURL, isEnabled: respectIgnoreRules)
        var result: [String: FolderSnapshotEntry] = [:]

        try await scanDirectory(
            rootURL: rootURL,
            directoryURL: rootURL,
            parentRelativePath: "",
            showHiddenFiles: showHiddenFiles,
            useContentHash: useContentHash,
            ignoreMatcher: ignoreMatcher,
            result: &result
        )

        return result
    }

    static func compare(
        left: [String: FolderSnapshotEntry],
        right: [String: FolderSnapshotEntry]
    ) -> [FolderCompareEntry] {
        let keys = Set(left.keys).union(right.keys)

        return keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { key in
                let leftEntry = left[key]
                let rightEntry = right[key]
                return FolderCompareEntry(
                    relativePath: key,
                    left: leftEntry,
                    right: rightEntry,
                    status: status(left: leftEntry, right: rightEntry)
                )
            }
    }

    static func plan(
        entries: [FolderCompareEntry],
        mode: FolderSyncMode,
        leftRootURL: URL,
        rightRootURL: URL
    ) -> [FolderSyncPlanItem] {
        let backupFolderName = "backup/\(backupTimestamp())"
        var items: [FolderSyncPlanItem] = []

        for entry in entries where entry.status != .same {
            switch mode {
            case .mirror:
                switch entry.status {
                case .leftOnly, .differentSize, .differentModified, .differentContent, .typeDifference:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .copyLeftToRight,
                            relativePath: entry.relativePath,
                            source: entry.left,
                            destination: entry.right,
                            backupRelativePath: nil
                        )
                    )
                case .rightOnly:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .deleteRight,
                            relativePath: entry.relativePath,
                            source: nil,
                            destination: entry.right,
                            backupRelativePath: nil
                        )
                    )
                case .same:
                    break
                }
            case .update:
                switch entry.status {
                case .leftOnly, .differentSize, .differentModified, .differentContent, .typeDifference:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .copyLeftToRight,
                            relativePath: entry.relativePath,
                            source: entry.left,
                            destination: entry.right,
                            backupRelativePath: nil
                        )
                    )
                case .rightOnly, .same:
                    break
                }
            case .twoWay:
                switch entry.status {
                case .leftOnly:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .copyLeftToRight,
                            relativePath: entry.relativePath,
                            source: entry.left,
                            destination: entry.right,
                            backupRelativePath: nil
                        )
                    )
                case .rightOnly:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .copyRightToLeft,
                            relativePath: entry.relativePath,
                            source: entry.right,
                            destination: entry.left,
                            backupRelativePath: nil
                        )
                    )
                case .differentSize, .differentModified, .differentContent, .typeDifference:
                    items.append(twoWayPlanItem(for: entry))
                case .same:
                    break
                }
            case .backup:
                switch entry.status {
                case .leftOnly, .differentSize, .differentModified, .differentContent, .typeDifference:
                    items.append(
                        FolderSyncPlanItem(
                            kind: .backupLeftToRight,
                            relativePath: entry.relativePath,
                            source: entry.left,
                            destination: nil,
                            backupRelativePath: backupFolderName.appendingRelativePathComponent(entry.relativePath)
                        )
                    )
                case .rightOnly, .same:
                    break
                }
            }
        }

        return items.sorted(by: syncPlanSort(_:_:))
    }

    static func sync(
        planItems: [FolderSyncPlanItem],
        mode: FolderSyncMode,
        dryRun: Bool,
        leftRootURL: URL,
        rightRootURL: URL,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async -> SyncResult {
        var rows: [FolderSyncLogRow] = []
        let total = planItems.count

        for (index, item) in planItems.enumerated() {
            await progress(index + 1, total)

            let actionTitle = L10n.string(item.kind.titleKey)

            if dryRun {
                rows.append(logRow(action: actionTitle, path: item.displayPath, result: "Dry Run", message: ""))
                continue
            }

            do {
                try await perform(item, leftRootURL: leftRootURL, rightRootURL: rightRootURL)
                rows.append(logRow(action: actionTitle, path: item.displayPath, result: "OK", message: ""))
            } catch {
                rows.append(
                    logRow(
                        action: actionTitle,
                        path: item.displayPath,
                        result: "Error",
                        message: error.localizedDescription
                    )
                )
            }
        }

        let logURL = try? writeLog(rows: rows, mode: mode, leftRootURL: leftRootURL, rightRootURL: rightRootURL)
        return SyncResult(rows: rows, logURL: logURL)
    }

    private static func scanDirectory(
        rootURL: URL,
        directoryURL: URL,
        parentRelativePath: String,
        showHiddenFiles: Bool,
        useContentHash: Bool,
        ignoreMatcher: IgnoreMatcher,
        result: inout [String: FolderSnapshotEntry]
    ) async throws {
        let items = try await listItems(at: directoryURL, showHiddenFiles: showHiddenFiles)

        for item in items {
            let relativePath = parentRelativePath.appendingRelativePathComponent(item.displayName)

            guard showHiddenFiles || !item.isHidden,
                  !ignoreMatcher.isIgnored(relativePath: relativePath, isDirectory: item.isDirectory) else {
                continue
            }

            let contentHash: String?

            if useContentHash,
               item.url.isFileURL,
               !item.isDirectory {
                contentHash = try? sha256(for: item.url)
            } else {
                contentHash = nil
            }

            result[relativePath] = FolderSnapshotEntry(
                relativePath: relativePath,
                url: item.url,
                isDirectory: item.isDirectory,
                isPackage: item.isPackage,
                size: item.size,
                modifiedAt: item.modifiedAt,
                contentHash: contentHash
            )

            if item.isDirectory && !item.isPackage {
                try await scanDirectory(
                    rootURL: rootURL,
                    directoryURL: item.url,
                    parentRelativePath: relativePath,
                    showHiddenFiles: showHiddenFiles,
                    useContentHash: useContentHash,
                    ignoreMatcher: ignoreMatcher,
                    result: &result
                )
            }
        }
    }

    private static func resolvedRootURL(_ url: URL) async throws -> URL {
        if SFTPClient.isSFTPURL(url) {
            return try await SFTPClient.resolvedDirectoryURL(for: url)
        }

        if S3Client.isS3URL(url) {
            return try S3Client.resolvedDirectoryURL(for: url)
        }

        return url.standardizedFileURL
    }

    private static func listItems(at url: URL, showHiddenFiles: Bool) async throws -> [FileItem] {
        if SFTPClient.isSFTPURL(url) {
            return try await SFTPClient.listDirectory(at: url, showHiddenFiles: showHiddenFiles).items
        }

        if S3Client.isS3URL(url) {
            return try await S3Client.listDirectory(at: url, showHiddenFiles: showHiddenFiles).items
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .localizedNameKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]

        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )
        .map(FileItem.load)
    }

    private static func status(left: FolderSnapshotEntry?, right: FolderSnapshotEntry?) -> FolderCompareStatus {
        switch (left, right) {
        case (.some, .none):
            return .leftOnly
        case (.none, .some):
            return .rightOnly
        case (.none, .none):
            return .same
        case let (.some(left), .some(right)):
            guard left.isDirectory == right.isDirectory else {
                return .typeDifference
            }

            guard !left.isDirectory else {
                return .same
            }

            if let leftSize = left.size,
               let rightSize = right.size,
               leftSize != rightSize {
                return .differentSize
            }

            if let leftHash = left.contentHash,
               let rightHash = right.contentHash,
               leftHash != rightHash {
                return .differentContent
            }

            if modifiedTimesDiffer(left.modifiedAt, right.modifiedAt) {
                return .differentModified
            }

            return .same
        }
    }

    private static func modifiedTimesDiffer(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else {
            return false
        }

        return abs(left.timeIntervalSince1970 - right.timeIntervalSince1970) > 1
    }

    private static func twoWayPlanItem(for entry: FolderCompareEntry) -> FolderSyncPlanItem {
        guard let left = entry.left,
              let right = entry.right,
              let leftDate = left.modifiedAt,
              let rightDate = right.modifiedAt else {
            return FolderSyncPlanItem(
                kind: .conflict,
                relativePath: entry.relativePath,
                source: entry.left,
                destination: entry.right,
                backupRelativePath: nil
            )
        }

        if leftDate > rightDate {
            return FolderSyncPlanItem(
                kind: .copyLeftToRight,
                relativePath: entry.relativePath,
                source: left,
                destination: right,
                backupRelativePath: nil
            )
        }

        if rightDate > leftDate {
            return FolderSyncPlanItem(
                kind: .copyRightToLeft,
                relativePath: entry.relativePath,
                source: right,
                destination: left,
                backupRelativePath: nil
            )
        }

        return FolderSyncPlanItem(
            kind: .conflict,
            relativePath: entry.relativePath,
            source: left,
            destination: right,
            backupRelativePath: nil
        )
    }

    private static func syncPlanSort(_ left: FolderSyncPlanItem, _ right: FolderSyncPlanItem) -> Bool {
        if left.kind == .deleteRight || right.kind == .deleteRight {
            return pathDepth(left.relativePath) > pathDepth(right.relativePath)
        }

        if left.source?.isDirectory == true, right.source?.isDirectory != true {
            return true
        }

        if left.source?.isDirectory != true, right.source?.isDirectory == true {
            return false
        }

        return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
    }

    private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    private static func perform(
        _ item: FolderSyncPlanItem,
        leftRootURL: URL,
        rightRootURL: URL
    ) async throws {
        switch item.kind {
        case .copyLeftToRight:
            guard let source = item.source else {
                return
            }

            try await copy(
                source: source,
                destinationURL: url(for: source.relativePath, rootURL: rightRootURL, isDirectory: source.isDirectory)
            )
        case .copyRightToLeft:
            guard let source = item.source else {
                return
            }

            try await copy(
                source: source,
                destinationURL: url(for: source.relativePath, rootURL: leftRootURL, isDirectory: source.isDirectory)
            )
        case .backupLeftToRight:
            guard let source = item.source,
                  let backupRelativePath = item.backupRelativePath else {
                return
            }

            try await copy(
                source: source,
                destinationURL: url(for: backupRelativePath, rootURL: rightRootURL, isDirectory: source.isDirectory)
            )
        case .deleteRight:
            guard let destination = item.destination else {
                return
            }

            try await remove(destination.url)
        case .conflict:
            throw FolderCompareSyncError.unsupportedSync(L10n.string("Conflict requires manual resolution."))
        case .unchanged:
            return
        }
    }

    static func copy(source: FolderSnapshotEntry, destinationURL: URL) async throws {
        if source.isDirectory && !source.isPackage {
            try await createDirectory(at: destinationURL)
            return
        }

        let parentURL = parentURL(for: destinationURL)
        try await createDirectory(at: parentURL)

        if destinationURL.isFileURL {
            try? FileManager.default.removeItem(at: destinationURL)
        } else {
            try? await remove(destinationURL)
        }

        switch (storageKind(for: source.url), storageKind(for: destinationURL)) {
        case (.local, .local):
            try FileManager.default.copyItem(at: source.url, to: destinationURL)
        case (.local, .sftp):
            try await SFTPClient.upload(localURLs: [source.url], to: parentURL)
        case (.local, .s3):
            try await S3Client.upload(localURLs: [source.url], to: parentURL)
        case (.sftp, .local):
            try await SFTPClient.download(remoteURLs: [source.url], to: parentURL)
        case (.s3, .local):
            try await S3Client.download(remoteURLs: [source.url], to: parentURL)
        case (.s3, .s3):
            try await S3Client.copy(from: source.url, to: destinationURL)
        case (.sftp, .sftp), (.sftp, .s3), (.s3, .sftp):
            try await copyViaTemporaryFile(source: source, destinationParentURL: parentURL)
        }
    }

    private static func copyViaTemporaryFile(
        source: FolderSnapshotEntry,
        destinationParentURL: URL
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShodanaFolderSync", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        switch storageKind(for: source.url) {
        case .sftp:
            try await SFTPClient.download(remoteURLs: [source.url], to: tempDirectory)
        case .s3:
            try await S3Client.download(remoteURLs: [source.url], to: tempDirectory)
        case .local:
            try FileManager.default.copyItem(
                at: source.url,
                to: tempDirectory.appendingPathComponent(source.url.lastPathComponent)
            )
        }

        let localURL = tempDirectory.appendingPathComponent(source.url.lastPathComponent)

        switch storageKind(for: destinationParentURL) {
        case .sftp:
            try await SFTPClient.upload(localURLs: [localURL], to: destinationParentURL)
        case .s3:
            try await S3Client.upload(localURLs: [localURL], to: destinationParentURL)
        case .local:
            try FileManager.default.copyItem(
                at: localURL,
                to: destinationParentURL.appendingPathComponent(localURL.lastPathComponent)
            )
        }
    }

    private static func createDirectory(at url: URL) async throws {
        switch storageKind(for: url) {
        case .local:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        case .sftp:
            try await SFTPClient.createDirectory(at: url)
        case .s3:
            try await S3Client.createDirectory(at: url)
        }
    }

    private static func remove(_ url: URL) async throws {
        switch storageKind(for: url) {
        case .local:
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        case .sftp:
            try await SFTPClient.remove([url])
        case .s3:
            try await S3Client.remove([url])
        }
    }

    private enum StorageKind {
        case local
        case sftp
        case s3
    }

    private static func storageKind(for url: URL) -> StorageKind {
        if SFTPClient.isSFTPURL(url) {
            return .sftp
        }

        if S3Client.isS3URL(url) {
            return .s3
        }

        return .local
    }

    private static func url(for relativePath: String, rootURL: URL, isDirectory: Bool) -> URL {
        let components = relativePath.split(separator: "/").map(String.init)

        switch storageKind(for: rootURL) {
        case .local:
            return components.reduce(rootURL) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: false)
            }
        case .sftp:
            let basePath = SFTPClient.remotePath(for: rootURL)
            let path = components.reduce(basePath) { partialPath, component in
                partialPath.appendingRemotePathComponent(component)
            }
            return SFTPClient.url(bySettingPath: path, on: rootURL)
        case .s3:
            let basePrefix = S3Client.directoryPrefix(for: rootURL)
            let prefix = components.reduce(basePrefix) { partialPath, component in
                partialPath.appendingS3PrefixComponent(component)
            }
            return S3Client.url(bySettingPrefix: isDirectory ? directoryPrefix(prefix) : prefix, on: rootURL)
        }
    }

    private static func parentURL(for url: URL) -> URL {
        switch storageKind(for: url) {
        case .local:
            return url.deletingLastPathComponent()
        case .sftp:
            return SFTPClient.parentURL(for: url)
        case .s3:
            return S3Client.parentURL(for: url)
        }
    }

    private static func directoryPrefix(_ prefix: String) -> String {
        let trimmed = prefix.trimmingTrailingSlash
        return trimmed.isEmpty ? "" : "\(trimmed)/"
    }

    private static func sha256(for url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        var hasher = SHA256()

        while true {
            let data = try fileHandle.read(upToCount: 1024 * 1024) ?? Data()

            guard !data.isEmpty else {
                break
            }

            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func logRow(action: String, path: String, result: String, message: String) -> FolderSyncLogRow {
        FolderSyncLogRow(timestamp: Date(), action: action, path: path, result: result, message: message)
    }

    private static func writeLog(
        rows: [FolderSyncLogRow],
        mode: FolderSyncMode,
        leftRootURL: URL,
        rightRootURL: URL
    ) throws -> URL {
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Shodana", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let filename = "FolderSync-\(backupTimestamp()).csv"
        let logURL = logDirectory.appendingPathComponent(filename)
        let header = "timestamp,mode,left,right,action,path,result,message\n"
        let body = rows.map { row in
            [
                csv(DateFormatter.folderSyncLog.string(from: row.timestamp)),
                csv(mode.rawValue),
                csv(leftRootURL.absoluteString),
                csv(rightRootURL.absoluteString),
                csv(row.action),
                csv(row.path),
                csv(row.result),
                csv(row.message)
            ].joined(separator: ",")
        }
        .joined(separator: "\n")

        try (header + body + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        return logURL
    }

    private static func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func backupTimestamp() -> String {
        DateFormatter.folderSyncTimestamp.string(from: Date())
    }
}

private struct IgnoreMatcher {
    private let isEnabled: Bool
    private let patterns: [String]

    init(rootURL: URL, isEnabled: Bool) throws {
        self.isEnabled = isEnabled

        guard isEnabled else {
            patterns = []
            return
        }

        var values = [
            ".git",
            "node_modules",
            "dist",
            "build",
            ".DS_Store",
            "Thumbs.db",
            "*.log",
            "*.tmp",
            "*.cache"
        ]

        if rootURL.isFileURL {
            let gitignoreURL = rootURL.appendingPathComponent(".gitignore")

            if let text = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
                values.append(
                    contentsOf: text
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
                )
            }
        }

        patterns = values
    }

    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        guard isEnabled else {
            return false
        }

        let components = relativePath.split(separator: "/").map(String.init)
        let filename = components.last ?? relativePath

        for pattern in patterns.reversed() {
            let normalizedPattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            guard !normalizedPattern.isEmpty else {
                continue
            }

            if normalizedPattern.contains("*") {
                if wildcardMatch(filename, pattern: normalizedPattern) || wildcardMatch(relativePath, pattern: normalizedPattern) {
                    return true
                }
            } else if components.contains(normalizedPattern) || relativePath == normalizedPattern || relativePath.hasPrefix("\(normalizedPattern)/") {
                return true
            }
        }

        return false
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*") + "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }
}

struct FolderCompareLocationChoice: Identifiable, Hashable {
    var id: String {
        if url.isFileURL {
            return "\(sectionTitle)-\(url.standardizedFileURL.path)"
        }

        return "\(sectionTitle)-\(url.absoluteString)"
    }

    let sectionTitle: String
    let title: String
    let url: URL
}

struct FolderCompareSyncSheet: View {
    @StateObject private var viewModel: FolderCompareSyncViewModel
    @Environment(\.dismiss) private var dismiss
    private let locationChoices: [FolderCompareLocationChoice]
    @State private var selectedDetailEntry: FolderCompareEntry?

    init(
        leftInitialURL: URL,
        rightInitialURL: URL,
        showHiddenFiles: Bool,
        locationChoices: [FolderCompareLocationChoice] = []
    ) {
        self.locationChoices = locationChoices
        _viewModel = StateObject(
            wrappedValue: FolderCompareSyncViewModel(
                leftInitialURL: leftInitialURL,
                rightInitialURL: rightInitialURL,
                showHiddenFiles: showHiddenFiles
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            controls

            Divider()

            VSplitView {
                resultArea
                    .frame(minHeight: 260, maxHeight: .infinity)

                syncControls
                    .frame(minHeight: 170, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 980,
            idealWidth: 1180,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .background(ResizableSheetWindowConfigurator(minSize: NSSize(width: 980, height: 680)))
        .sheet(item: $selectedDetailEntry) { entry in
            FolderCompareDetailSheet(entry: entry)
        }
        .alert(
            L10n.string("Action Failed"),
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.clearError()
                    }
                }
            )
        ) {
            Button(L10n.string("OK")) {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Folder Compare / Sync"))
                .font(.headline)

            Spacer()

            Button(L10n.string("Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.string("Left"))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField(L10n.string("Left Folder"), text: $viewModel.leftText)
                            .textFieldStyle(.roundedBorder)

                        locationMenu { url in
                            viewModel.leftText = displayString(for: url)
                        }

                        Button {
                            chooseFolder(title: "Choose Left Folder", currentText: viewModel.leftText) { url in
                                viewModel.leftText = url.path
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help(L10n.string("Choose Folder"))
                    }
                }

                GridRow {
                    Text(L10n.string("Right"))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField(L10n.string("Right Folder"), text: $viewModel.rightText)
                            .textFieldStyle(.roundedBorder)

                        locationMenu { url in
                            viewModel.rightText = displayString(for: url)
                        }

                        Button {
                            chooseFolder(title: "Choose Right Folder", currentText: viewModel.rightText) { url in
                                viewModel.rightText = url.path
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help(L10n.string("Choose Folder"))
                    }
                }
            }

            HStack(spacing: 12) {
                Toggle(L10n.string("Use SHA-256 for local files"), isOn: $viewModel.useContentHash)
                Toggle(L10n.string("Respect ignore rules"), isOn: $viewModel.respectIgnoreRules)

                Spacer()

                if viewModel.isComparing {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.progressText)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.string("Compare")) {
                    viewModel.compare()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isComparing || viewModel.isSyncing)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func locationMenu(selection: @escaping (URL) -> Void) -> some View {
        Menu {
            ForEach(groupedLocationChoices, id: \.sectionTitle) { group in
                Section(L10n.string(group.sectionTitle)) {
                    ForEach(group.choices) { choice in
                        Button(choice.title) {
                            selection(choice.url)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .menuStyle(.button)
        .help(L10n.string("Select from Shodana Locations"))
    }

    private var groupedLocationChoices: [(sectionTitle: String, choices: [FolderCompareLocationChoice])] {
        var groups: [(sectionTitle: String, choices: [FolderCompareLocationChoice])] = []

        for choice in locationChoices {
            if let index = groups.firstIndex(where: { $0.sectionTitle == choice.sectionTitle }) {
                groups[index].choices.append(choice)
            } else {
                groups.append((sectionTitle: choice.sectionTitle, choices: [choice]))
            }
        }

        return groups
    }

    private func chooseFolder(title: String, currentText: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L10n.string(title)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = localDirectoryURL(from: currentText)

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func localDirectoryURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              !trimmed.lowercased().hasPrefix("sftp://"),
              !trimmed.lowercased().hasPrefix("s3://") else {
            return nil
        }

        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }

        return url.deletingLastPathComponent()
    }

    private func displayString(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) {
            return SFTPClient.displayString(for: url)
        }

        if S3Client.isS3URL(url) {
            return S3Client.displayString(for: url)
        }

        return url.path
    }

    private var resultArea: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.summaryText)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(
                    String(
                        format: L10n.string("%d of %d selected for sync"),
                        viewModel.selectedSyncCount,
                        viewModel.syncCandidateCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(L10n.string("Select All")) {
                    viewModel.selectAllSyncCandidates()
                }
                .disabled(!viewModel.hasSyncCandidates || viewModel.areAllSyncCandidatesSelected)

                Button(L10n.string("Clear All")) {
                    viewModel.clearAllSyncCandidates()
                }
                .disabled(!viewModel.hasSyncCandidates || viewModel.selectedSyncCount == 0)

                Picker(L10n.string("Filter"), selection: $viewModel.filter) {
                    ForEach(FolderCompareFilter.allCases) { filter in
                        Text(L10n.string(filter.titleKey)).tag(filter)
                    }
                }
                .frame(width: 240)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            FolderCompareHeaderRow()

            if viewModel.filteredEntries.isEmpty {
                Spacer()
                Text(L10n.string("No comparison results."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredEntries) { entry in
                            FolderCompareResultRow(
                                entry: entry,
                                isSyncCandidate: viewModel.isSyncCandidate(entry),
                                isSyncSelected: viewModel.isSyncSelected(entry),
                                onSyncSelectionChange: { isSelected in
                                    viewModel.setSyncSelected(isSelected, for: entry)
                                }
                            ) {
                                guard entry.canShowDetail else {
                                    return
                                }

                                selectedDetailEntry = entry
                            }
                        }
                    }
                }
            }
        }
    }

    private var syncControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(L10n.string("Sync Mode"), selection: $viewModel.syncMode) {
                    ForEach(FolderSyncMode.allCases) { mode in
                        Text(L10n.string(mode.titleKey)).tag(mode)
                    }
                }
                .frame(width: 180)

                Toggle(L10n.string("Dry Run"), isOn: $viewModel.dryRun)

                if viewModel.requiresLargeDeletionConfirmation {
                    Toggle(
                        String(format: L10n.string("Confirm delete count"), viewModel.deleteCount),
                        isOn: $viewModel.confirmLargeDeletion
                    )
                }

                Spacer()

                if viewModel.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.progressText)
                        .foregroundStyle(.secondary)
                }

                Button(viewModel.dryRun ? L10n.string("Preview Sync") : L10n.string("Run Sync")) {
                    viewModel.runSync()
                }
                .disabled(!viewModel.canRunSync)
            }

            Text(viewModel.planSummaryText)
                .foregroundStyle(.secondary)

            if let lastLogURL = viewModel.lastLogURL {
                Text(String(format: L10n.string("Sync log saved to %@"), lastLogURL.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !viewModel.logRows.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.logRows.prefix(80)) { row in
                            Text("\(row.result)  \(row.action)  \(row.path) \(row.message)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(row.result == "Error" ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

private struct ResizableSheetWindowConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureAsync(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureAsync(from: nsView)
    }

    private func configureAsync(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            window.styleMask.insert(.resizable)
            window.minSize = minSize
        }
    }
}

private struct FolderCompareHeaderRow: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(L10n.string("Sync"))
                .frame(width: 58, alignment: .leading)
            Text(L10n.string("Status"))
                .frame(width: 150, alignment: .leading)
            Text(L10n.string("Path"))
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            Text(L10n.string("Size Left"))
                .frame(width: 110, alignment: .trailing)
            Text(L10n.string("Size Right"))
                .frame(width: 110, alignment: .trailing)
            Text(L10n.string("Modified Left"))
                .frame(width: 150, alignment: .leading)
            Text(L10n.string("Modified Right"))
                .frame(width: 150, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FolderCompareResultRow: View {
    let entry: FolderCompareEntry
    let isSyncCandidate: Bool
    let isSyncSelected: Bool
    let onSyncSelectionChange: (Bool) -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSyncSelected },
                    set: { isSelected in
                        onSyncSelectionChange(isSelected)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!isSyncCandidate)
            .help(isSyncCandidate ? L10n.string("Include in sync") : L10n.string("No sync action in this mode"))
            .frame(width: 58, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 8, height: 8)

                Text(L10n.string(entry.status.titleKey))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            Text(entry.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)

            Text(sizeText(entry.left))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            Text(sizeText(entry.right))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            Text(dateText(entry.left))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(dateText(entry.right))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(entry.status == .same ? Color.clear : entry.status.color.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpenDetail()
        }
        .help(entry.canShowDetail ? L10n.string("Double-click to compare files") : "")
    }

    private func sizeText(_ entry: FolderSnapshotEntry?) -> String {
        guard let entry,
              !entry.isDirectory,
              let size = entry.size else {
            return "-"
        }

        return size.formatted(.byteCount(style: .file))
    }

    private func dateText(_ entry: FolderSnapshotEntry?) -> String {
        guard let date = entry?.modifiedAt else {
            return "-"
        }

        return date.formatted(date: .numeric, time: .shortened)
    }
}

private struct FolderCompareDetailSheet: View {
    let entry: FolderCompareEntry

    @Environment(\.dismiss) private var dismiss
    @State private var leftContent: FolderComparePreviewContent = .loading
    @State private var rightContent: FolderComparePreviewContent = .loading
    @State private var leftEditableText = ""
    @State private var rightEditableText = ""
    @State private var isApplyingAction = false
    @State private var actionMessage: String?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if hasTextComparison {
                mergeEditor
            } else {
                sideBySidePreview
            }
        }
        .frame(
            minWidth: 980,
            idealWidth: 1180,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .background(ResizableSheetWindowConfigurator(minSize: NSSize(width: 980, height: 620)))
        .task(id: entry.id) {
            await load()
        }
        .alert(
            L10n.string("Action Failed"),
            isPresented: Binding(
                get: { actionError != nil },
                set: { isPresented in
                    if !isPresented {
                        actionError = nil
                    }
                }
            )
        ) {
            Button(L10n.string("OK")) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("File Compare"))
                    .font(.headline)

                Text(entry.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isApplyingAction {
                ProgressView()
                    .controlSize(.small)
            }

            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if hasTextComparison {
                Button(L10n.string("Save Left")) {
                    saveText(to: [.left])
                }
                .disabled(!canSaveText(to: .left) || isApplyingAction)

                Button(L10n.string("Save Right")) {
                    saveText(to: [.right])
                }
                .disabled(!canSaveText(to: .right) || isApplyingAction)

                Button(L10n.string("Save Both")) {
                    saveText(to: [.left, .right])
                }
                .disabled(!canSaveText(to: .left) && !canSaveText(to: .right) || isApplyingAction)
            } else {
                Button(L10n.string("Use Left")) {
                    copy(source: entry.left, destination: entry.right, successKey: "Left version applied.")
                }
                .disabled(!canCopy(source: entry.left, destination: entry.right) || isApplyingAction)

                Button(L10n.string("Use Right")) {
                    copy(source: entry.right, destination: entry.left, successKey: "Right version applied.")
                }
                .disabled(!canCopy(source: entry.right, destination: entry.left) || isApplyingAction)
            }

            Button(L10n.string("Skip")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var sideBySidePreview: some View {
        HStack(spacing: 0) {
            FolderComparePreviewPane(
                title: "Left",
                snapshot: entry.left,
                content: leftContent
            )

            Divider()

            FolderComparePreviewPane(
                title: "Right",
                snapshot: entry.right,
                content: rightContent
            )
        }
    }

    private var mergeEditor: some View {
        HSplitView {
            FolderCompareEditableTextPane(
                title: "Left",
                snapshot: entry.left,
                text: $leftEditableText
            )
            .frame(minWidth: 360)

            FolderCompareDiffControlColumn(
                hunks: diffHunks,
                onCopyLeftToRight: { hunk in
                    apply(hunk, direction: .leftToRight)
                },
                onCopyRightToLeft: { hunk in
                    apply(hunk, direction: .rightToLeft)
                }
            )
            .frame(minWidth: 92, idealWidth: 104, maxWidth: 128)

            FolderCompareEditableTextPane(
                title: "Right",
                snapshot: entry.right,
                text: $rightEditableText
            )
            .frame(minWidth: 360)
        }
    }

    private var diffHunks: [FolderCompareDiffHunk] {
        FolderCompareLineMerger.hunks(leftText: leftEditableText, rightText: rightEditableText)
    }

    private func apply(_ hunk: FolderCompareDiffHunk, direction: FolderCompareMergeDirection) {
        switch direction {
        case .leftToRight:
            let leftLines = FolderCompareLineMerger.lines(in: leftEditableText)
            let replacement = Array(leftLines[safe: hunk.leftRange])
            rightEditableText = FolderCompareLineMerger.replacingLines(
                in: rightEditableText,
                range: hunk.rightRange,
                with: replacement
            )
        case .rightToLeft:
            let rightLines = FolderCompareLineMerger.lines(in: rightEditableText)
            let replacement = Array(rightLines[safe: hunk.rightRange])
            leftEditableText = FolderCompareLineMerger.replacingLines(
                in: leftEditableText,
                range: hunk.leftRange,
                with: replacement
            )
        }
    }

    private func canSaveText(to side: FolderCompareSide) -> Bool {
        switch side {
        case .left:
            return entry.left.map { !$0.isDirectory } ?? false
        case .right:
            return entry.right.map { !$0.isDirectory } ?? false
        }
    }

    private func saveText(to sides: [FolderCompareSide]) {
        let targetTexts = sides.compactMap { side -> (FolderSnapshotEntry, String)? in
            switch side {
            case .left:
                return entry.left.map { ($0, leftEditableText) }
            case .right:
                return entry.right.map { ($0, rightEditableText) }
            }
        }

        guard !targetTexts.isEmpty else {
            return
        }

        isApplyingAction = true
        actionMessage = nil
        actionError = nil

        Task {
            do {
                for (target, text) in targetTexts {
                    try await FolderCompareTextWriter.write(text, to: target.url)
                }

                await MainActor.run {
                    leftContent = .text(leftEditableText)
                    rightContent = .text(rightEditableText)
                    actionMessage = L10n.string("Text file saved.")
                    isApplyingAction = false
                }
            } catch {
                await MainActor.run {
                    actionError = error.localizedDescription
                    isApplyingAction = false
                }
            }
        }
    }

    private func load() async {
        async let left = loadContent(for: entry.left)
        async let right = loadContent(for: entry.right)
        let values = await (left, right)

        await MainActor.run {
            leftContent = values.0
            rightContent = values.1
            leftEditableText = values.0.textValue ?? ""
            rightEditableText = values.1.textValue ?? ""
        }
    }

    private func loadContent(for snapshot: FolderSnapshotEntry?) async -> FolderComparePreviewContent {
        guard let snapshot else {
            return .missing
        }

        do {
            let localURL = try await localPreviewURL(for: snapshot)

            if isImage(localURL) {
                if let image = NSImage(contentsOf: localURL) {
                    return .image(image)
                }
            }

            if isLikelyText(localURL),
               let text = try? String(contentsOf: localURL, encoding: .utf8) {
                return .text(text)
            }

            return .metadata(
                [
                    "\(L10n.string("Path")): \(snapshot.url.absoluteString)",
                    "\(L10n.string("Size")): \(snapshot.size?.formatted(.byteCount(style: .file)) ?? "-")",
                    "\(L10n.string("Modified")): \(snapshot.modifiedAt?.formatted(date: .numeric, time: .standard) ?? "-")"
                ]
                .joined(separator: "\n")
            )
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func localPreviewURL(for snapshot: FolderSnapshotEntry) async throws -> URL {
        if snapshot.url.isFileURL {
            return snapshot.url
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShodanaComparePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        if SFTPClient.isSFTPURL(snapshot.url) {
            try await SFTPClient.download(remoteURLs: [snapshot.url], to: tempDirectory)
        } else if S3Client.isS3URL(snapshot.url) {
            try await S3Client.download(remoteURLs: [snapshot.url], to: tempDirectory)
        }

        return tempDirectory.appendingPathComponent(snapshot.url.lastPathComponent)
    }

    private func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased())
    }

    private func isLikelyText(_ url: URL) -> Bool {
        let textExtensions = [
            "txt", "md", "markdown", "swift", "json", "yaml", "yml", "xml", "html", "css",
            "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "c", "h", "cpp",
            "hpp", "sh", "zsh", "sql", "toml", "ini", "plist", "csv"
        ]

        if textExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }

        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        return !data.contains(0)
    }

    private var hasTextComparison: Bool {
        leftContent.textValue != nil || rightContent.textValue != nil
    }

    private func canCopy(source: FolderSnapshotEntry?, destination: FolderSnapshotEntry?) -> Bool {
        guard let source, let destination else {
            return false
        }

        return !source.isDirectory && !destination.isDirectory
    }

    private func copy(source: FolderSnapshotEntry?, destination: FolderSnapshotEntry?, successKey: String) {
        guard let source, let destination else {
            return
        }

        isApplyingAction = true
        actionMessage = nil
        actionError = nil

        Task {
            do {
                try await FolderCompareSyncEngine.copy(source: source, destinationURL: destination.url)
                await load()

                await MainActor.run {
                    actionMessage = L10n.string(successKey)
                    isApplyingAction = false
                }
            } catch {
                await MainActor.run {
                    actionError = error.localizedDescription
                    isApplyingAction = false
                }
            }
        }
    }
}

private enum FolderCompareSide {
    case left
    case right
}

private enum FolderCompareMergeDirection {
    case leftToRight
    case rightToLeft
}

private struct FolderCompareDiffHunk: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let leftRange: Range<Int>
    let rightRange: Range<Int>

    var title: String {
        String(format: L10n.string("Difference %d"), index)
    }

    var leftLineText: String {
        lineText(for: leftRange)
    }

    var rightLineText: String {
        lineText(for: rightRange)
    }

    private func lineText(for range: Range<Int>) -> String {
        guard !range.isEmpty else {
            return "-"
        }

        if range.count == 1 {
            return "\(range.lowerBound + 1)"
        }

        return "\(range.lowerBound + 1)-\(range.upperBound)"
    }
}

private struct FolderCompareEditableTextPane: View {
    let title: String
    let snapshot: FolderSnapshotEntry?
    @Binding var text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string(title))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(snapshot?.url.absoluteString.removingPercentEncoding ?? "-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            SyntaxHighlightedTextView(
                text: $text,
                fileExtension: snapshot?.url.pathExtension.lowercased() ?? ""
            )
        }
    }
}

private struct FolderCompareDiffControlColumn: View {
    let hunks: [FolderCompareDiffHunk]
    let onCopyLeftToRight: (FolderCompareDiffHunk) -> Void
    let onCopyRightToLeft: (FolderCompareDiffHunk) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("Merge"))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

            Divider()

            if hunks.isEmpty {
                Spacer()
                Text(L10n.string("No text differences."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(hunks) { hunk in
                            VStack(spacing: 6) {
                                Text(hunk.title)
                                    .font(.caption.weight(.semibold))

                                Text("L \(hunk.leftLineText) / R \(hunk.rightLineText)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                Button("<<") {
                                    onCopyRightToLeft(hunk)
                                }
                                .help(L10n.string("Copy Right to Left"))

                                Button(">>") {
                                    onCopyLeftToRight(hunk)
                                }
                                .help(L10n.string("Copy Left to Right"))
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SyntaxHighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    let fileExtension: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.applyHighlighting(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedTextView
        private var isApplyingHighlighting = false

        init(_ parent: SyntaxHighlightedTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlighting else {
                return
            }

            isApplyingHighlighting = true
            defer {
                isApplyingHighlighting = false
            }

            let selectedRanges = textView.selectedRanges
            FolderCompareSyntaxHighlighter.apply(
                to: textView.textStorage,
                text: textView.string,
                fileExtension: parent.fileExtension
            )
            textView.selectedRanges = selectedRanges
        }
    }
}

@MainActor
private enum FolderCompareSyntaxHighlighter {
    static func apply(to textStorage: NSTextStorage?, text: String, fileExtension: String) {
        guard let textStorage else {
            return
        }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes, range: fullRange)

        guard !text.isEmpty else {
            textStorage.endEditing()
            return
        }

        let language = HighlightLanguage(fileExtension: fileExtension)
        applyPatterns(language.patterns, to: textStorage, text: text, fullRange: fullRange)
        textStorage.endEditing()
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func applyPatterns(
        _ patterns: [HighlightPattern],
        to textStorage: NSTextStorage,
        text: String,
        fullRange: NSRange
    ) {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.pattern, options: pattern.options) else {
                continue
            }

            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match else {
                    return
                }

                textStorage.addAttribute(.foregroundColor, value: pattern.color, range: match.range)
                if let font = pattern.font {
                    textStorage.addAttribute(.font, value: font, range: match.range)
                }
            }
        }
    }

    private struct HighlightPattern {
        let pattern: String
        let color: NSColor
        let options: NSRegularExpression.Options
        let font: NSFont?

        init(
            _ pattern: String,
            color: NSColor,
            options: NSRegularExpression.Options = [],
            font: NSFont? = nil
        ) {
            self.pattern = pattern
            self.color = color
            self.options = options
            self.font = font
        }
    }

    private enum HighlightLanguage {
        case cFamily
        case swift
        case python
        case shell
        case sql
        case markup
        case css
        case json
        case yaml
        case markdown
        case plain

        init(fileExtension: String) {
            switch fileExtension {
            case "js", "jsx", "ts", "tsx", "java", "cs", "c", "h", "cpp", "cc", "cxx", "hpp", "hxx":
                self = .cFamily
            case "swift":
                self = .swift
            case "py", "rb":
                self = .python
            case "sh", "zsh", "bash":
                self = .shell
            case "sql":
                self = .sql
            case "html", "xml":
                self = .markup
            case "css", "scss", "sass":
                self = .css
            case "json", "jsonc":
                self = .json
            case "yaml", "yml", "toml", "ini":
                self = .yaml
            case "md", "markdown":
                self = .markdown
            default:
                self = .plain
            }
        }

        @MainActor
        var patterns: [HighlightPattern] {
            switch self {
            case .cFamily:
                return cFamilyPatterns
            case .swift:
                return swiftPatterns
            case .python:
                return pythonPatterns
            case .shell:
                return shellPatterns
            case .sql:
                return sqlPatterns
            case .markup:
                return markupPatterns
            case .css:
                return cssPatterns
            case .json:
                return jsonPatterns
            case .yaml:
                return yamlPatterns
            case .markdown:
                return markdownPatterns
            case .plain:
                return []
            }
        }
    }

    private static let keywordColor = NSColor.systemPurple
    private static let stringColor = NSColor.systemGreen
    private static let commentColor = NSColor.secondaryLabelColor
    private static let numberColor = NSColor.systemOrange
    private static let typeColor = NSColor.systemTeal
    private static let attributeColor = NSColor.systemBlue
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    private static var cFamilyPatterns: [HighlightPattern] {
        [
            blockCommentPattern,
            lineCommentPattern("//"),
            quotedStringPattern,
            numberPattern,
            keywordPattern([
                "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "default", "delegate", "delete", "do", "else", "enum", "event", "export", "extends", "false",
                "finally", "for", "foreach", "from", "function", "get", "if", "implements", "import", "in",
                "instanceof", "interface", "let", "namespace", "new", "null", "override", "package", "private",
                "protected", "public", "readonly", "return", "set", "static", "struct", "super", "switch",
                "this", "throw", "throws", "true", "try", "typeof", "using", "var", "virtual", "void", "while",
                "yield"
            ]),
            keywordPattern([
                "Array", "Boolean", "Date", "Double", "Error", "Float", "Int", "Integer", "List", "Map",
                "Number", "Object", "Promise", "Record", "Set", "String", "boolean", "char", "double",
                "float", "int", "long", "short", "string"
            ], color: typeColor)
        ]
    }

    private static var swiftPatterns: [HighlightPattern] {
        [
            blockCommentPattern,
            lineCommentPattern("//"),
            quotedStringPattern,
            numberPattern,
            keywordPattern([
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard",
                "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return",
                "self", "static", "struct", "switch", "throw", "throws", "true", "try", "typealias", "var",
                "where", "while"
            ]),
            keywordPattern(["Any", "Array", "Bool", "Data", "Date", "Dictionary", "Double", "Error", "Float", "Int", "Set", "String", "URL"], color: typeColor)
        ]
    }

    private static var pythonPatterns: [HighlightPattern] {
        [
            lineCommentPattern("#"),
            quotedStringPattern,
            numberPattern,
            keywordPattern([
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
                "try", "while", "with", "yield"
            ])
        ]
    }

    private static var shellPatterns: [HighlightPattern] {
        [
            lineCommentPattern("#"),
            quotedStringPattern,
            numberPattern,
            keywordPattern(["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "until", "while"])
        ]
    }

    private static var sqlPatterns: [HighlightPattern] {
        [
            lineCommentPattern("--"),
            HighlightPattern(#"/\*[\s\S]*?\*/"#, color: commentColor),
            quotedStringPattern,
            numberPattern,
            keywordPattern([
                "ADD", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC",
                "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "GROUP", "HAVING", "IN", "INDEX",
                "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON",
                "OR", "ORDER", "OUTER", "RIGHT", "SELECT", "SET", "TABLE", "THEN", "UNION", "UPDATE",
                "VALUES", "WHEN", "WHERE"
            ], options: [.caseInsensitive])
        ]
    }

    private static var markupPatterns: [HighlightPattern] {
        [
            HighlightPattern(#"<!--[\s\S]*?-->"#, color: commentColor),
            HighlightPattern(#"</?[\w:-]+"#, color: keywordColor),
            HighlightPattern(#"\s[\w:-]+(?=\=)"#, color: attributeColor),
            quotedStringPattern
        ]
    }

    private static var cssPatterns: [HighlightPattern] {
        [
            blockCommentPattern,
            quotedStringPattern,
            HighlightPattern(#"#[0-9a-fA-F]{3,8}\b"#, color: numberColor),
            HighlightPattern(#"[\w-]+(?=\s*:)"#, color: attributeColor),
            keywordPattern(["auto", "block", "flex", "grid", "inherit", "inline", "none", "relative", "absolute", "fixed", "sticky"], color: keywordColor)
        ]
    }

    private static var jsonPatterns: [HighlightPattern] {
        [
            HighlightPattern(#""(?:\\.|[^"\\])*"(?=\s*:)"#, color: attributeColor),
            quotedStringPattern,
            numberPattern,
            keywordPattern(["true", "false", "null"])
        ]
    }

    private static var yamlPatterns: [HighlightPattern] {
        [
            lineCommentPattern("#"),
            HighlightPattern(#"(?m)^\s*[\w.-]+(?=\s*:)"#, color: attributeColor),
            quotedStringPattern,
            numberPattern,
            keywordPattern(["true", "false", "null", "yes", "no", "on", "off"])
        ]
    }

    private static var markdownPatterns: [HighlightPattern] {
        [
            HighlightPattern(#"(?m)^#{1,6}\s.*$"#, color: keywordColor, font: boldFont),
            HighlightPattern(#"`[^`]*`"#, color: stringColor),
            HighlightPattern(#"(?m)^\s*[-*+]\s+"#, color: attributeColor),
            HighlightPattern(#"\[[^\]]+\]\([^)]+\)"#, color: attributeColor)
        ]
    }

    private static var blockCommentPattern: HighlightPattern {
        HighlightPattern(#"/\*[\s\S]*?\*/"#, color: commentColor)
    }

    private static func lineCommentPattern(_ prefix: String) -> HighlightPattern {
        HighlightPattern("(?m)\(NSRegularExpression.escapedPattern(for: prefix)).*$", color: commentColor)
    }

    private static var quotedStringPattern: HighlightPattern {
        HighlightPattern(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: stringColor)
    }

    private static var numberPattern: HighlightPattern {
        HighlightPattern(#"\b\d+(?:\.\d+)?\b"#, color: numberColor)
    }

    private static func keywordPattern(
        _ words: [String],
        color: NSColor = keywordColor,
        options: NSRegularExpression.Options = []
    ) -> HighlightPattern {
        let escaped = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return HighlightPattern(#"\b("# + escaped + #")\b"#, color: color, options: options, font: boldFont)
    }
}

private enum FolderCompareLineMerger {
    private enum Operation {
        case same(leftIndex: Int, rightIndex: Int)
        case leftOnly(Int)
        case rightOnly(Int)
    }

    static func hunks(leftText: String, rightText: String) -> [FolderCompareDiffHunk] {
        let leftLines = lines(in: leftText)
        let rightLines = lines(in: rightText)
        let operations = makeOperations(leftLines: leftLines, rightLines: rightLines)
        return diffHunks(from: operations)
    }

    static func lines(in text: String) -> [String] {
        return text.components(separatedBy: "\n")
    }

    static func replacingLines(in text: String, range: Range<Int>, with replacement: [String]) -> String {
        var values = lines(in: text)
        let safeLowerBound = min(max(range.lowerBound, 0), values.count)
        let safeUpperBound = min(max(range.upperBound, safeLowerBound), values.count)
        values.replaceSubrange(safeLowerBound..<safeUpperBound, with: replacement)
        return values.joined(separator: "\n")
    }

    private static func makeOperations(leftLines: [String], rightLines: [String]) -> [Operation] {
        let comparisonSize = leftLines.count * rightLines.count

        guard comparisonSize <= 1_000_000 else {
            return zipByIndex(leftCount: leftLines.count, rightCount: rightLines.count)
        }

        var table = Array(
            repeating: Array(repeating: 0, count: rightLines.count + 1),
            count: leftLines.count + 1
        )

        if !leftLines.isEmpty && !rightLines.isEmpty {
            for leftIndex in stride(from: leftLines.count - 1, through: 0, by: -1) {
                for rightIndex in stride(from: rightLines.count - 1, through: 0, by: -1) {
                    if leftLines[leftIndex] == rightLines[rightIndex] {
                        table[leftIndex][rightIndex] = table[leftIndex + 1][rightIndex + 1] + 1
                    } else {
                        table[leftIndex][rightIndex] = max(
                            table[leftIndex + 1][rightIndex],
                            table[leftIndex][rightIndex + 1]
                        )
                    }
                }
            }
        }

        var operations: [Operation] = []
        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < leftLines.count && rightIndex < rightLines.count {
            if leftLines[leftIndex] == rightLines[rightIndex] {
                operations.append(.same(leftIndex: leftIndex, rightIndex: rightIndex))
                leftIndex += 1
                rightIndex += 1
            } else if table[leftIndex + 1][rightIndex] >= table[leftIndex][rightIndex + 1] {
                operations.append(.leftOnly(leftIndex))
                leftIndex += 1
            } else {
                operations.append(.rightOnly(rightIndex))
                rightIndex += 1
            }
        }

        while leftIndex < leftLines.count {
            operations.append(.leftOnly(leftIndex))
            leftIndex += 1
        }

        while rightIndex < rightLines.count {
            operations.append(.rightOnly(rightIndex))
            rightIndex += 1
        }

        return operations
    }

    private static func zipByIndex(leftCount: Int, rightCount: Int) -> [Operation] {
        var operations: [Operation] = []
        let maxCount = max(leftCount, rightCount)

        for index in 0..<maxCount {
            switch (index < leftCount, index < rightCount) {
            case (true, true):
                operations.append(.same(leftIndex: index, rightIndex: index))
            case (true, false):
                operations.append(.leftOnly(index))
            case (false, true):
                operations.append(.rightOnly(index))
            case (false, false):
                break
            }
        }

        return operations
    }

    private static func diffHunks(from operations: [Operation]) -> [FolderCompareDiffHunk] {
        var hunks: [FolderCompareDiffHunk] = []
        var index = 0

        while index < operations.count {
            switch operations[index] {
            case .same:
                index += 1
            case .leftOnly, .rightOnly:
                let (leftRange, rightRange, nextIndex) = collectDifferenceRun(
                    from: operations,
                    startIndex: index
                )
                hunks.append(
                    FolderCompareDiffHunk(
                        index: hunks.count + 1,
                        leftRange: leftRange,
                        rightRange: rightRange
                    )
                )
                index = nextIndex
            }
        }

        return hunks
    }

    private static func collectDifferenceRun(
        from operations: [Operation],
        startIndex: Int
    ) -> (leftRange: Range<Int>, rightRange: Range<Int>, nextIndex: Int) {
        var leftIndexes: [Int] = []
        var rightIndexes: [Int] = []
        var index = startIndex

        while index < operations.count {
            switch operations[index] {
            case .leftOnly(let leftIndex):
                leftIndexes.append(leftIndex)
            case .rightOnly(let rightIndex):
                rightIndexes.append(rightIndex)
            case .same:
                return (
                    range(
                        from: leftIndexes,
                        operations: operations,
                        startIndex: startIndex,
                        nextIndex: index,
                        side: .left
                    ),
                    range(
                        from: rightIndexes,
                        operations: operations,
                        startIndex: startIndex,
                        nextIndex: index,
                        side: .right
                    ),
                    index
                )
            }

            index += 1
        }

        return (
            range(from: leftIndexes, operations: operations, startIndex: startIndex, nextIndex: index, side: .left),
            range(from: rightIndexes, operations: operations, startIndex: startIndex, nextIndex: index, side: .right),
            index
        )
    }

    private enum DiffSide {
        case left
        case right
    }

    private static func range(
        from indexes: [Int],
        operations: [Operation],
        startIndex: Int,
        nextIndex: Int,
        side: DiffSide
    ) -> Range<Int> {
        guard let first = indexes.first,
              let last = indexes.last else {
            let insertionIndex = insertionPoint(
                operations: operations,
                startIndex: startIndex,
                nextIndex: nextIndex,
                side: side
            )
            return insertionIndex..<insertionIndex
        }

        return first..<(last + 1)
    }

    private static func insertionPoint(
        operations: [Operation],
        startIndex: Int,
        nextIndex: Int,
        side: DiffSide
    ) -> Int {
        if nextIndex < operations.count,
           case .same(let leftIndex, let rightIndex) = operations[nextIndex] {
            return side == .left ? leftIndex : rightIndex
        }

        if startIndex > 0 {
            switch operations[startIndex - 1] {
            case .same(let leftIndex, let rightIndex):
                return (side == .left ? leftIndex : rightIndex) + 1
            case .leftOnly(let leftIndex):
                return side == .left ? leftIndex + 1 : 0
            case .rightOnly(let rightIndex):
                return side == .right ? rightIndex + 1 : 0
            }
        }

        return 0
    }
}

private enum FolderCompareTextWriter {
    static func write(_ text: String, to url: URL) async throws {
        if url.isFileURL {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShodanaMergeSave", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let tempFile = tempDirectory.appendingPathComponent(fileName(for: url))
        try text.write(to: tempFile, atomically: true, encoding: .utf8)

        if SFTPClient.isSFTPURL(url) {
            try await SFTPClient.upload(localURLs: [tempFile], to: SFTPClient.parentURL(for: url))
            return
        }

        if S3Client.isS3URL(url) {
            try await S3Client.upload(localURLs: [tempFile], to: S3Client.parentURL(for: url))
            return
        }

        throw FolderCompareSyncError.unsupportedSync(L10n.string("Unsupported merge destination."))
    }

    private static func fileName(for url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "merged.txt" : name
    }
}

private enum FolderComparePreviewContent {
    case loading
    case missing
    case text(String)
    case image(NSImage)
    case metadata(String)
    case error(String)

    var textValue: String? {
        if case .text(let text) = self {
            return text
        }

        return nil
    }
}

private struct FolderComparePreviewPane: View {
    let title: String
    let snapshot: FolderSnapshotEntry?
    let content: FolderComparePreviewContent

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string(title))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(snapshot?.url.absoluteString.removingPercentEncoding ?? "-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .missing:
            Text(L10n.string("Missing"))
                .foregroundStyle(.secondary)
        case .text(let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .image(let image):
            ScrollView([.vertical, .horizontal]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .metadata(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(12)
        }
    }
}

private extension DateFormatter {
    static let folderSyncTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static let folderSyncLog: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmingTrailingSlash: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }

    func appendingRelativePathComponent(_ component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedComponent.isEmpty else {
            return self
        }

        if isEmpty {
            return trimmedComponent
        }

        return "\(self.trimmingTrailingSlash)/\(trimmedComponent)"
    }

    func appendingRemotePathComponent(_ component: String) -> String {
        if self == "/" {
            return "/\(component)"
        }

        return "\(self.trimmingTrailingSlash)/\(component)"
    }

    func appendingS3PrefixComponent(_ component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !trimmedComponent.isEmpty else {
            return self
        }

        if isEmpty {
            return trimmedComponent
        }

        return hasSuffix("/") ? "\(self)\(trimmedComponent)" : "\(self)/\(trimmedComponent)"
    }

    func isDescendant(of parentPath: String) -> Bool {
        let normalizedParent = parentPath.trimmingTrailingSlash

        guard !normalizedParent.isEmpty else {
            return !isEmpty
        }

        return hasPrefix("\(normalizedParent)/")
    }
}

private extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lowerBound = Swift.max(0, Swift.min(range.lowerBound, count))
        let upperBound = Swift.max(lowerBound, Swift.min(range.upperBound, count))
        return self[lowerBound..<upperBound]
    }
}
