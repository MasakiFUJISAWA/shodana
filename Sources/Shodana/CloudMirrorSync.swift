import AppKit
import Foundation
import SwiftUI

enum CloudMirrorSyncSchedule: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case manual
    case onLaunch
    case hourly
    case daily
    case weekly

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .manual:
            return "Manual"
        case .onLaunch:
            return "On Launch"
        case .hourly:
            return "Hourly"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        }
    }

    var systemImageName: String {
        switch self {
        case .manual:
            return "hand.point.up.left"
        case .onLaunch:
            return "power"
        case .hourly:
            return "clock"
        case .daily:
            return "calendar"
        case .weekly:
            return "calendar.badge.clock"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .manual, .onLaunch:
            return nil
        case .hourly:
            return 60 * 60
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        }
    }

    func isDue(lastRunAt: Date?, now: Date, isLaunch: Bool) -> Bool {
        switch self {
        case .manual:
            return false
        case .onLaunch:
            return isLaunch
        case .hourly, .daily, .weekly:
            guard let interval else {
                return false
            }

            guard let lastRunAt else {
                return true
            }

            return now.timeIntervalSince(lastRunAt) >= interval
        }
    }
}

struct CloudMirrorSyncJob: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var sourceText: String
    var destinationText: String
    var useContentHash: Bool
    var respectIgnoreRules: Bool
    var dryRun: Bool
    var schedule: CloudMirrorSyncSchedule
    var largeDeletionThreshold: Int
    var lastAutomaticRunAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sourceText: String,
        destinationText: String,
        useContentHash: Bool = true,
        respectIgnoreRules: Bool = true,
        dryRun: Bool = true,
        schedule: CloudMirrorSyncSchedule = .manual,
        largeDeletionThreshold: Int = 10,
        lastAutomaticRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceText = sourceText
        self.destinationText = destinationText
        self.useContentHash = useContentHash
        self.respectIgnoreRules = respectIgnoreRules
        self.dryRun = dryRun
        self.schedule = schedule
        self.largeDeletionThreshold = largeDeletionThreshold
        self.lastAutomaticRunAt = lastAutomaticRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var normalized: CloudMirrorSyncJob {
        CloudMirrorSyncJob(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? L10n.string("Untitled Mirror Job"),
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationText: destinationText.trimmingCharacters(in: .whitespacesAndNewlines),
            useContentHash: useContentHash,
            respectIgnoreRules: respectIgnoreRules,
            dryRun: dryRun,
            schedule: schedule,
            largeDeletionThreshold: max(1, largeDeletionThreshold),
            lastAutomaticRunAt: lastAutomaticRunAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum CloudMirrorSyncJobStore {
    private static let defaultsKey = "Shodana.cloudMirrorSyncJobs"
    private static let legacyDefaultsKeys = ["Mihako.cloudMirrorSyncJobs"]

    static func load() -> [CloudMirrorSyncJob] {
        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys),
              let jobs = try? JSONDecoder().decode([CloudMirrorSyncJob].self, from: data) else {
            return []
        }

        return jobs.map(\.normalized)
    }

    static func save(_ jobs: [CloudMirrorSyncJob]) {
        guard let data = try? JSONEncoder().encode(jobs.map(\.normalized)) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct CloudMirrorSyncRunResult {
    let planItems: [FolderSyncPlanItem]
    let syncResult: FolderCompareSyncEngine.SyncResult
}

enum CloudMirrorSyncJobRunner {
    static func buildPlan(
        job: CloudMirrorSyncJob,
        showHiddenFiles: Bool
    ) async throws -> [FolderSyncPlanItem] {
        let normalizedJob = job.normalized
        let sourceURL = try folderURL(from: normalizedJob.sourceText)
        let destinationURL = try folderURL(from: normalizedJob.destinationText)

        guard folderIdentity(for: sourceURL) != folderIdentity(for: destinationURL) else {
            throw FolderCompareSyncError.unsupportedSync(L10n.string("Source and destination must be different."))
        }

        async let leftSnapshot = FolderCompareSyncEngine.scan(
            rootURL: sourceURL,
            showHiddenFiles: showHiddenFiles,
            respectIgnoreRules: normalizedJob.respectIgnoreRules,
            useContentHash: normalizedJob.useContentHash
        )
        async let rightSnapshot = FolderCompareSyncEngine.scan(
            rootURL: destinationURL,
            showHiddenFiles: showHiddenFiles,
            respectIgnoreRules: normalizedJob.respectIgnoreRules,
            useContentHash: normalizedJob.useContentHash
        )

        let entries = try await FolderCompareSyncEngine.compare(
            left: leftSnapshot,
            right: rightSnapshot
        )

        return FolderCompareSyncEngine.plan(
            entries: entries,
            mode: .mirror,
            leftRootURL: sourceURL,
            rightRootURL: destinationURL
        )
    }

    static func run(
        job: CloudMirrorSyncJob,
        showHiddenFiles: Bool,
        dryRun: Bool,
        allowLargeDeletion: Bool,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> CloudMirrorSyncRunResult {
        let normalizedJob = job.normalized
        let sourceURL = try folderURL(from: normalizedJob.sourceText)
        let destinationURL = try folderURL(from: normalizedJob.destinationText)
        let planItems = try await buildPlan(job: normalizedJob, showHiddenFiles: showHiddenFiles)
        let deleteCount = planItems.filter { $0.kind == .deleteRight }.count

        if !dryRun,
           deleteCount >= normalizedJob.largeDeletionThreshold,
           !allowLargeDeletion {
            throw FolderCompareSyncError.unsupportedSync(
                String(format: L10n.string("Confirm cloud mirror delete count"), deleteCount)
            )
        }

        let result = await FolderCompareSyncEngine.sync(
            planItems: planItems,
            mode: .mirror,
            dryRun: dryRun,
            leftRootURL: sourceURL,
            rightRootURL: destinationURL,
            progress: progress
        )

        return CloudMirrorSyncRunResult(planItems: planItems, syncResult: result)
    }

    static func folderURL(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw FolderCompareSyncError.invalidURL(text)
        }

        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("sftp://") || lowercased.hasPrefix("s3://") || lowercased.hasPrefix("file://") {
            guard let url = URL(string: trimmed) else {
                throw FolderCompareSyncError.invalidURL(text)
            }

            return url
        }

        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    static func displayString(for url: URL) -> String {
        if SFTPClient.isSFTPURL(url) {
            return SFTPClient.displayString(for: url)
        }

        if S3Client.isS3URL(url) {
            return S3Client.displayString(for: url)
        }

        return url.path
    }

    private static func folderIdentity(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path.trimmingTrailingSlash
        }

        return url.absoluteString.trimmingTrailingSlash
    }
}

@MainActor
enum CloudMirrorSyncJobScheduler {
    private static let pollIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    private static var schedulerTask: Task<Void, Never>?
    private static var isRunningAutomaticJobs = false

    static func startIfNeeded(showHiddenFiles: Bool) {
        guard schedulerTask == nil else {
            return
        }

        schedulerTask = Task {
            await runDueJobs(showHiddenFiles: showHiddenFiles, isLaunch: true)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                } catch {
                    return
                }

                await runDueJobs(showHiddenFiles: showHiddenFiles, isLaunch: false)
            }
        }
    }

    private static func runDueJobs(showHiddenFiles: Bool, isLaunch: Bool) async {
        guard !isRunningAutomaticJobs else {
            return
        }

        let now = Date()
        let jobs = CloudMirrorSyncJobStore.load().filter {
            $0.schedule.isDue(lastRunAt: $0.lastAutomaticRunAt, now: now, isLaunch: isLaunch)
        }

        guard !jobs.isEmpty else {
            return
        }

        isRunningAutomaticJobs = true

        for job in jobs {
            _ = try? await CloudMirrorSyncJobRunner.run(
                job: job,
                showHiddenFiles: showHiddenFiles,
                dryRun: job.dryRun,
                allowLargeDeletion: false
            ) { _, _ in }

            markAutomaticRun(jobID: job.id)
        }

        isRunningAutomaticJobs = false
    }

    private static func markAutomaticRun(jobID: UUID) {
        var jobs = CloudMirrorSyncJobStore.load()

        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }

        jobs[index].lastAutomaticRunAt = Date()
        CloudMirrorSyncJobStore.save(jobs)
    }
}

@MainActor
final class CloudMirrorSyncJobsViewModel: ObservableObject {
    @Published private(set) var jobs: [CloudMirrorSyncJob]
    @Published var selectedJobID: UUID?
    @Published var name = ""
    @Published var sourceText: String
    @Published var destinationText: String
    @Published var useContentHash = true
    @Published var respectIgnoreRules = true
    @Published var dryRun = true
    @Published var schedule: CloudMirrorSyncSchedule = .manual
    @Published var largeDeletionThreshold = 10
    @Published private(set) var planItems: [FolderSyncPlanItem] = []
    @Published private(set) var logRows: [FolderSyncLogRow] = []
    @Published private(set) var isPreviewing = false
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var lastLogURL: URL?
    @Published private(set) var errorMessage: String?
    @Published var confirmLargeDeletion = false

    private let sourceInitialText: String
    private let destinationInitialText: String
    private let showHiddenFiles: Bool

    init(sourceInitialURL: URL, destinationInitialURL: URL, showHiddenFiles: Bool) {
        sourceInitialText = CloudMirrorSyncJobRunner.displayString(for: sourceInitialURL)
        destinationInitialText = CloudMirrorSyncJobRunner.displayString(for: destinationInitialURL)
        sourceText = sourceInitialText
        destinationText = destinationInitialText
        self.showHiddenFiles = showHiddenFiles
        jobs = CloudMirrorSyncJobStore.load()

        if let firstJob = jobs.first {
            load(job: firstJob)
        } else {
            prepareNewJob()
        }
    }

    var isBusy: Bool {
        isPreviewing || isRunning
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    var canPreview: Bool {
        canSave
    }

    var canRun: Bool {
        canSave
            && !planItems.isEmpty
            && (!requiresLargeDeletionConfirmation || confirmLargeDeletion || dryRun)
    }

    var deleteCount: Int {
        planItems.filter { $0.kind == .deleteRight }.count
    }

    var copyCount: Int {
        planItems.filter { $0.kind == .copyLeftToRight }.count
    }

    var requiresLargeDeletionConfirmation: Bool {
        !dryRun && deleteCount >= max(1, largeDeletionThreshold)
    }

    var planSummaryText: String {
        guard !planItems.isEmpty else {
            return L10n.string("No mirror actions.")
        }

        return String(
            format: L10n.string("cloud.mirror.plan.summary"),
            copyCount,
            deleteCount
        )
    }

    func selectJob(id: UUID?) {
        guard selectedJobID != id else {
            return
        }

        selectedJobID = id

        if let id,
           let job = jobs.first(where: { $0.id == id }) {
            load(job: job)
        } else {
            prepareNewJob()
        }
    }

    func prepareNewJob() {
        selectedJobID = nil
        name = L10n.string("New Mirror Job")
        sourceText = sourceInitialText
        destinationText = destinationInitialText
        useContentHash = true
        respectIgnoreRules = true
        dryRun = true
        schedule = .manual
        largeDeletionThreshold = 10
        clearRunState()
    }

    func saveJob() {
        guard canSave,
              let job = draftJob() else {
            errorMessage = L10n.string("Fill in the mirror job name, source, and destination.")
            return
        }

        if let selectedJobID,
           let index = jobs.firstIndex(where: { $0.id == selectedJobID }) {
            jobs[index] = job
        } else {
            jobs.append(job)
            selectedJobID = job.id
        }

        CloudMirrorSyncJobStore.save(jobs)
    }

    func deleteSelectedJob() {
        guard let selectedJobID,
              let index = jobs.firstIndex(where: { $0.id == selectedJobID }),
              !isBusy else {
            return
        }

        jobs.remove(at: index)
        CloudMirrorSyncJobStore.save(jobs)

        if let nextJob = jobs[safe: min(index, jobs.count - 1)] {
            load(job: nextJob)
        } else {
            prepareNewJob()
        }
    }

    func preview() {
        guard canPreview,
              let job = draftJob() else {
            errorMessage = L10n.string("Fill in the mirror job name, source, and destination.")
            return
        }

        isPreviewing = true
        clearRunState(keepingPlan: false)
        progressText = L10n.string("Scanning folders...")

        Task {
            do {
                let plan = try await CloudMirrorSyncJobRunner.buildPlan(
                    job: job,
                    showHiddenFiles: showHiddenFiles
                )

                await MainActor.run {
                    self.planItems = plan
                    self.confirmLargeDeletion = false
                    self.progressText = ""
                    self.isPreviewing = false
                }
            } catch {
                await MainActor.run {
                    self.planItems = []
                    self.progressText = ""
                    self.isPreviewing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func run() {
        guard canSave,
              let job = draftJob() else {
            errorMessage = L10n.string("Fill in the mirror job name, source, and destination.")
            return
        }

        isRunning = true
        clearRunState(keepingPlan: true)
        progressText = dryRun ? L10n.string("Dry Run") : L10n.string("Syncing...")

        Task {
            do {
                let result = try await CloudMirrorSyncJobRunner.run(
                    job: job,
                    showHiddenFiles: showHiddenFiles,
                    dryRun: dryRun,
                    allowLargeDeletion: confirmLargeDeletion
                ) { completed, total in
                    await MainActor.run {
                        self.progressText = "\(completed) / \(total)"
                    }
                }

                await MainActor.run {
                    self.planItems = result.planItems
                    self.logRows = result.syncResult.rows
                    self.lastLogURL = result.syncResult.logURL
                    self.progressText = ""
                    self.isRunning = false
                    self.confirmLargeDeletion = false
                    self.saveJob()
                }
            } catch {
                await MainActor.run {
                    self.progressText = ""
                    self.isRunning = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func load(job: CloudMirrorSyncJob) {
        let normalizedJob = job.normalized
        selectedJobID = normalizedJob.id
        name = normalizedJob.name
        sourceText = normalizedJob.sourceText
        destinationText = normalizedJob.destinationText
        useContentHash = normalizedJob.useContentHash
        respectIgnoreRules = normalizedJob.respectIgnoreRules
        dryRun = normalizedJob.dryRun
        schedule = normalizedJob.schedule
        largeDeletionThreshold = normalizedJob.largeDeletionThreshold
        clearRunState()
    }

    private func draftJob() -> CloudMirrorSyncJob? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDestination = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty,
              !trimmedSource.isEmpty,
              !trimmedDestination.isEmpty else {
            return nil
        }

        let existingJob = selectedJobID.flatMap { id in
            jobs.first { $0.id == id }
        }

        return CloudMirrorSyncJob(
            id: existingJob?.id ?? UUID(),
            name: trimmedName,
            sourceText: trimmedSource,
            destinationText: trimmedDestination,
            useContentHash: useContentHash,
            respectIgnoreRules: respectIgnoreRules,
            dryRun: dryRun,
            schedule: schedule,
            largeDeletionThreshold: max(1, largeDeletionThreshold),
            lastAutomaticRunAt: existingJob?.lastAutomaticRunAt,
            createdAt: existingJob?.createdAt ?? Date(),
            updatedAt: Date()
        )
        .normalized
    }

    private func clearRunState(keepingPlan: Bool = false) {
        if !keepingPlan {
            planItems = []
        }

        logRows = []
        lastLogURL = nil
        progressText = ""
        errorMessage = nil
        confirmLargeDeletion = false
    }
}

struct CloudMirrorSyncJobsSheet: View {
    @StateObject private var viewModel: CloudMirrorSyncJobsViewModel
    @Environment(\.dismiss) private var dismiss

    private let locationChoices: [FolderCompareLocationChoice]

    init(
        sourceInitialURL: URL,
        destinationInitialURL: URL,
        showHiddenFiles: Bool,
        locationChoices: [FolderCompareLocationChoice] = []
    ) {
        self.locationChoices = locationChoices
        _viewModel = StateObject(
            wrappedValue: CloudMirrorSyncJobsViewModel(
                sourceInitialURL: sourceInitialURL,
                destinationInitialURL: destinationInitialURL,
                showHiddenFiles: showHiddenFiles
            )
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            jobList
                .frame(width: 300)

            Divider()

            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        jobEditor
                        previewArea
                        logArea
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(
            minWidth: 980,
            idealWidth: 1120,
            maxWidth: .infinity,
            minHeight: 660,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .background(ResizableSheetWindowConfigurator(minSize: NSSize(width: 980, height: 660)))
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

    private var jobList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Mirror Jobs"))
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.prepareNewJob()
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.string("New Mirror Job"))
            }
            .padding(12)

            Divider()

            List(
                selection: Binding(
                    get: { viewModel.selectedJobID },
                    set: { viewModel.selectJob(id: $0) }
                )
            ) {
                ForEach(viewModel.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name)
                            .font(.headline)
                            .lineLimit(1)

                        Text("\(job.sourceText) -> \(job.destinationText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if job.schedule != .manual {
                            Label(L10n.string(job.schedule.titleKey), systemImage: job.schedule.systemImageName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(job.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(role: .destructive) {
                viewModel.deleteSelectedJob()
            } label: {
                Label(L10n.string("Delete Job"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.selectedJobID == nil || viewModel.isBusy)
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Cloud Mirror Sync"))
                .font(.headline)

            Spacer()

            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.progressText)
                    .foregroundStyle(.secondary)
            }

            Button(L10n.string("Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var jobEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Mirror Job Settings"))
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.string("Job Name"))
                        .foregroundStyle(.secondary)

                    TextField(L10n.string("Job Name"), text: $viewModel.name)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text(L10n.string("Source"))
                        .foregroundStyle(.secondary)

                    pathControls(text: $viewModel.sourceText, title: "Choose Source Folder")
                }

                GridRow {
                    Text(L10n.string("Destination"))
                        .foregroundStyle(.secondary)

                    pathControls(text: $viewModel.destinationText, title: "Choose Destination Folder")
                }

                GridRow {
                    Text(L10n.string("Delete Warning"))
                        .foregroundStyle(.secondary)

                    Stepper(
                        String(format: L10n.string("Warn when deleting %d or more items"), viewModel.largeDeletionThreshold),
                        value: $viewModel.largeDeletionThreshold,
                        in: 1...999
                    )
                }
            }

            HStack(spacing: 14) {
                Toggle(L10n.string("Use SHA-256 for local files"), isOn: $viewModel.useContentHash)
                Toggle(L10n.string("Respect ignore rules"), isOn: $viewModel.respectIgnoreRules)
                Toggle(L10n.string("Dry Run"), isOn: $viewModel.dryRun)

                Picker(L10n.string("Schedule"), selection: $viewModel.schedule) {
                    ForEach(CloudMirrorSyncSchedule.allCases) { schedule in
                        Label(L10n.string(schedule.titleKey), systemImage: schedule.systemImageName)
                            .tag(schedule)
                    }
                }
                .frame(width: 190)

                Spacer()
            }

            HStack {
                Text(L10n.string("Mirror copies new and updated items from source to destination, then deletes destination-only items."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.string("Save Job")) {
                    viewModel.saveJob()
                }
                .disabled(!viewModel.canSave)

                Button(L10n.string("Preview Mirror")) {
                    viewModel.preview()
                }
                .disabled(!viewModel.canPreview)

                Button(viewModel.dryRun ? L10n.string("Dry Run") : L10n.string("Run Mirror")) {
                    viewModel.run()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canRun || viewModel.isBusy)
            }

            if viewModel.requiresLargeDeletionConfirmation {
                Toggle(
                    String(format: L10n.string("Confirm cloud mirror delete count"), viewModel.deleteCount),
                    isOn: $viewModel.confirmLargeDeletion
                )
                .toggleStyle(.checkbox)
                .foregroundStyle(.red)
            }
        }
    }

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("Mirror Preview"))
                    .font(.headline)

                Spacer()

                Text(viewModel.planSummaryText)
                    .foregroundStyle(.secondary)
            }

            if viewModel.planItems.isEmpty {
                Text(L10n.string("No mirror actions."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.planItems) { item in
                            CloudMirrorSyncPlanRow(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 180, maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
            }
        }
    }

    private var logArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("Sync Log"))
                    .font(.headline)

                Spacer()

                if let lastLogURL = viewModel.lastLogURL {
                    Text(lastLogURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if viewModel.logRows.isEmpty {
                Text(L10n.string("No sync log yet."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.logRows.prefix(160)) { row in
                            Text("\(row.result)  \(row.action)  \(row.path) \(row.message)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(row.result == "Error" ? Color.red : Color.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 110, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
            }
        }
    }

    private func pathControls(text: Binding<String>, title: String) -> some View {
        HStack(spacing: 8) {
            TextField(L10n.string(title), text: text)
                .textFieldStyle(.roundedBorder)

            locationMenu { url in
                text.wrappedValue = CloudMirrorSyncJobRunner.displayString(for: url)
            }

            Button {
                chooseFolder(title: title, currentText: text.wrappedValue) { url in
                    text.wrappedValue = url.path
                }
            } label: {
                Image(systemName: "folder")
            }
            .help(L10n.string("Choose Folder"))
        }
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
}

private struct CloudMirrorSyncPlanRow: View {
    let item: FolderSyncPlanItem

    private var color: Color {
        switch item.kind {
        case .copyLeftToRight:
            return .green
        case .deleteRight:
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(L10n.string(item.kind.titleKey))
                .frame(width: 160, alignment: .leading)

            Text(item.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(color.opacity(0.08))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }

        return self[index]
    }
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
}
