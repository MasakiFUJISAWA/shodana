import Foundation
import Security

enum SearchInteractionMode: String, CaseIterable, Identifiable {
    case keyword
    case ai

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .keyword:
            return "Keyword Search"
        case .ai:
            return "AI Search"
        }
    }

    var systemImageName: String {
        switch self {
        case .keyword:
            return "magnifyingglass"
        case .ai:
            return "sparkles"
        }
    }
}

struct AIStorageScope: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var path: String
    var keepAcrossAIModeChanges: Bool

    init(id: UUID = UUID(), title: String, path: String, keepAcrossAIModeChanges: Bool = true) {
        self.id = id
        self.title = title
        self.path = path
        self.keepAcrossAIModeChanges = keepAcrossAIModeChanges
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case path
        case keepAcrossAIModeChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        keepAcrossAIModeChanges = try container.decodeIfPresent(Bool.self, forKey: .keepAcrossAIModeChanges) ?? true
    }

    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    var normalized: AIStorageScope {
        let normalizedURL = url
        let fallbackTitle = FileManager.default.displayName(atPath: normalizedURL.path).aiNilIfEmpty
            ?? normalizedURL.lastPathComponent.aiNilIfEmpty
            ?? normalizedURL.path
        return AIStorageScope(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).aiNilIfEmpty ?? fallbackTitle,
            path: normalizedURL.path,
            keepAcrossAIModeChanges: keepAcrossAIModeChanges
        )
    }
}

struct AISearchSettings: Codable, Hashable, Sendable {
    var endpointURLString: String
    var model: String
    var scopes: [AIStorageScope]
    var excludedPatternsText: String
    var maxFiles: Int
    var maxFileBytes: Int
    var maxContextCharacters: Int

    static let defaultExcludedPatterns = """
    .git
    node_modules
    dist
    build
    .build
    .DS_Store
    .env
    .env.*
    *.pem
    *.key
    *.p12
    *.mobileprovision
    *.xcuserstate
    *.log
    *.tmp
    *.cache
    """

    static let defaultSettings = AISearchSettings(
        endpointURLString: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o-mini",
        scopes: [],
        excludedPatternsText: defaultExcludedPatterns,
        maxFiles: 24,
        maxFileBytes: 64 * 1024,
        maxContextCharacters: 28_000
    )

    var normalized: AISearchSettings {
        AISearchSettings(
            endpointURLString: endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: scopes.map(\.normalized),
            excludedPatternsText: excludedPatternsText,
            maxFiles: max(4, min(maxFiles, 80)),
            maxFileBytes: max(4 * 1024, min(maxFileBytes, 512 * 1024)),
            maxContextCharacters: max(4_000, min(maxContextCharacters, 120_000))
        )
    }

    var excludedPatterns: [String] {
        excludedPatternsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

enum AISearchSettingsStore {
    private static let defaultsKey = "Shodana.aiSearchSettings"
    private static let legacyDefaultsKeys = ["Mihako.aiSearchSettings"]

    static func load() -> AISearchSettings {
        guard let data = AppDefaults.migratedData(forKey: defaultsKey, legacyKeys: legacyDefaultsKeys),
              let settings = try? JSONDecoder().decode(AISearchSettings.self, from: data) else {
            return .defaultSettings
        }

        return settings.normalized
    }

    static func save(_ settings: AISearchSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum AIProviderSecretStore {
    private static let service = "dev.masakifujisawa.shodana.ai"
    private static let account = "chat-completions-api-key"

    static func loadAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            return nil
        }

        return apiKey
    }

    static func saveAPIKey(_ apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAPIKey.isEmpty else {
            deleteAPIKey()
            return
        }

        let data = Data(trimmedAPIKey.utf8)
        var query = baseQuery

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AIChatRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system

    var titleKey: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "AI"
        case .system:
            return "System"
        }
    }
}

struct AIChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: AIChatRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: AIChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct AIContextFile: Identifiable, Hashable, Sendable {
    var id: String { url.path }

    let url: URL
    let rootURL: URL
    let relativePath: String
    let snippet: String
    let matchSummary: String
    let isPathMatch: Bool
    let size: Int
    let modifiedAt: Date?
    let score: Int
}

struct AIContextBuildResult: Sendable {
    let files: [AIContextFile]
    let matchingPaths: [String]
    let scannedFileCount: Int
    let skippedFileCount: Int
}

enum AISearchError: Error, LocalizedError {
    case invalidEndpoint(String)
    case missingProviderConfiguration
    case providerError(String)
    case noReadableContext

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid AI endpoint: \(value)"
        case .missingProviderConfiguration:
            return "AI provider is not configured."
        case .providerError(let message):
            return message
        case .noReadableContext:
            return "No readable files were found in the AI scope."
        }
    }
}

enum AISearchContextBuilder {
    private static let textExtensions: Set<String> = [
        "applescript", "c", "cc", "conf", "cpp", "cs", "css", "csv", "env", "go",
        "h", "hpp", "htm", "html", "java", "js", "json", "jsx", "kt", "kts", "log",
        "m", "markdown", "md", "mm", "php", "plist", "properties", "py", "rb", "rs",
        "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]

    static func collectContext(
        question: String,
        rootURLs: [URL],
        settings: AISearchSettings
    ) async throws -> AIContextBuildResult {
        let normalizedSettings = settings.normalized
        let roots = rootURLs.map(\.standardizedFileURL)
        let patterns = normalizedSettings.excludedPatterns
        let queryTerms = searchTerms(from: question)

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isHiddenKey
            ]
            var candidates: [AIContextFile] = []
            var matchingPathCandidates: [(path: String, score: Int)] = []
            var scannedFileCount = 0
            var skippedFileCount = 0

            for rootURL in roots {
                guard FileManager.default.fileExists(atPath: rootURL.path) else {
                    continue
                }

                let enumerator = FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                ) { _, _ in
                    true
                }

                while let url = enumerator?.nextObject() as? URL {
                    try Task.checkCancellation()

                    let relativePath = relativePath(for: url, rootURL: rootURL)
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let isDirectory = values?.isDirectory == true
                    let pathScore = pathRelevanceScore(relativePath: relativePath, queryTerms: queryTerms)

                    if pathScore > 0 {
                        matchingPathCandidates.append((pathIndexLine(for: url, relativePath: relativePath), pathScore))
                    }

                    if isIgnored(relativePath: relativePath, name: url.lastPathComponent, patterns: patterns) {
                        if isDirectory {
                            enumerator?.skipDescendants()
                        }
                        skippedFileCount += 1
                        continue
                    }

                    if isDirectory {
                        if pathScore > 0 {
                            candidates.append(
                                AIContextFile(
                                    url: url,
                                    rootURL: rootURL,
                                    relativePath: relativePath,
                                    snippet: pathOnlySnippet(
                                        relativePath: relativePath,
                                        kind: "Directory",
                                        size: nil,
                                        modifiedAt: values?.contentModificationDate
                                    ),
                                    matchSummary: "matched path",
                                    isPathMatch: true,
                                    size: 0,
                                    modifiedAt: values?.contentModificationDate,
                                    score: pathScore
                                )
                            )
                        }

                        continue
                    }

                    guard values?.isRegularFile == true else {
                        continue
                    }

                    scannedFileCount += 1

                    guard isLikelyTextFile(url),
                          let size = values?.fileSize,
                          size <= normalizedSettings.maxFileBytes else {
                        if pathScore > 0 {
                            candidates.append(
                                AIContextFile(
                                    url: url,
                                    rootURL: rootURL,
                                    relativePath: relativePath,
                                    snippet: pathOnlySnippet(
                                        relativePath: relativePath,
                                        kind: "File",
                                        size: values?.fileSize,
                                        modifiedAt: values?.contentModificationDate
                                    ),
                                    matchSummary: "matched path; content not included",
                                    isPathMatch: true,
                                    size: values?.fileSize ?? 0,
                                    modifiedAt: values?.contentModificationDate,
                                    score: pathScore
                                )
                            )
                        }

                        skippedFileCount += 1
                        continue
                    }

                    guard let text = readTextPrefix(from: url, maxBytes: normalizedSettings.maxFileBytes) else {
                        if pathScore > 0 {
                            candidates.append(
                                AIContextFile(
                                    url: url,
                                    rootURL: rootURL,
                                    relativePath: relativePath,
                                    snippet: pathOnlySnippet(
                                        relativePath: relativePath,
                                        kind: "File",
                                        size: size,
                                        modifiedAt: values?.contentModificationDate
                                    ),
                                    matchSummary: "matched path; content not readable",
                                    isPathMatch: true,
                                    size: size,
                                    modifiedAt: values?.contentModificationDate,
                                    score: pathScore
                                )
                            )
                        }

                        skippedFileCount += 1
                        continue
                    }

                    let score = relevanceScore(
                        relativePath: relativePath,
                        text: text,
                        queryTerms: queryTerms,
                        pathScore: pathScore
                    )
                    guard score > 0 || candidates.count < normalizedSettings.maxFiles / 2 else {
                        continue
                    }

                    candidates.append(
                        AIContextFile(
                            url: url,
                            rootURL: rootURL,
                            relativePath: relativePath,
                            snippet: snippet(from: text, queryTerms: queryTerms),
                            matchSummary: matchSummary(relativePath: relativePath, text: text, queryTerms: queryTerms),
                            isPathMatch: pathScore > 0,
                            size: size,
                            modifiedAt: values?.contentModificationDate,
                            score: score
                        )
                    )
                }
            }

            let sortedCandidates = candidates.sorted(by: compareContextFiles)
            let pathMatchedFiles = sortedCandidates.filter(\.isPathMatch)
            let otherFiles = sortedCandidates.filter { !$0.isPathMatch }
            let files = Array((pathMatchedFiles + otherFiles).prefix(normalizedSettings.maxFiles))
            let matchingPaths = matchingPathCandidates
                .sorted { left, right in
                    if left.score == right.score {
                        return left.path.localizedStandardCompare(right.path) == .orderedAscending
                    }

                    return left.score > right.score
                }
                .map(\.path)
                .aiUniqued()
                .prefix(200)

            return AIContextBuildResult(
                files: Array(files),
                matchingPaths: Array(matchingPaths),
                scannedFileCount: scannedFileCount,
                skippedFileCount: skippedFileCount
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func compareContextFiles(_ left: AIContextFile, _ right: AIContextFile) -> Bool {
        if left.score == right.score {
            return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
        }

        return left.score > right.score
    }

    private static func pathIndexLine(for url: URL, relativePath: String) -> String {
        "\(url.path) (relative: \(relativePath))"
    }

    private static func searchTerms(from question: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let terms = question
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
        let asciiTerms = asciiIdentifierTerms(from: question)

        if !terms.isEmpty || !asciiTerms.isEmpty {
            var seen = Set<String>()
            return (terms + asciiTerms).filter { seen.insert($0).inserted }
        }

        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedQuestion.isEmpty ? [] : [normalizedQuestion]
    }

    private static func asciiIdentifierTerms(from question: String) -> [String] {
        var terms: [String] = []
        var current = ""

        for scalar in question.unicodeScalars {
            if CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
                .contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                terms.append(current.lowercased())
                current = ""
            }
        }

        if !current.isEmpty {
            terms.append(current.lowercased())
        }

        return terms.filter { $0.count >= 2 }
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.aiTrimmingTrailingSlash
        let path = url.path

        guard path.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        let relative = path.dropFirst(rootPath.count).drop { $0 == "/" }
        return relative.isEmpty ? url.lastPathComponent : String(relative)
    }

    private static func isIgnored(relativePath: String, name: String, patterns: [String]) -> Bool {
        let lowercasedPath = relativePath.lowercased()
        let lowercasedName = name.lowercased()

        return patterns.contains { rawPattern in
            let pattern = rawPattern.lowercased()

            if pattern.hasPrefix("*.") {
                return lowercasedName.hasSuffix(String(pattern.dropFirst()))
            }

            if pattern.hasSuffix("/*") {
                let prefix = String(pattern.dropLast(2))
                return lowercasedPath == prefix || lowercasedPath.hasPrefix(prefix + "/")
            }

            if pattern.contains("/") {
                return lowercasedPath == pattern || lowercasedPath.hasPrefix(pattern + "/")
            }

            return lowercasedName == pattern
                || lowercasedPath.split(separator: "/").contains(Substring(pattern))
        }
    }

    private static func isLikelyTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || textExtensions.contains(ext)
    }

    private static func readTextPrefix(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        let data = handle.readData(ofLength: maxBytes)

        guard !data.isEmpty,
              data.firstIndex(of: 0) == nil else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func pathRelevanceScore(relativePath: String, queryTerms: [String]) -> Int {
        guard !queryTerms.isEmpty else {
            return 1
        }

        let lowercasedPath = relativePath.lowercased()
        let filename = (lowercasedPath as NSString).lastPathComponent
        let filenameStem = (filename as NSString).deletingPathExtension
        let filenameExtension = (filename as NSString).pathExtension
        let tokens = pathTokens(from: lowercasedPath)
        var score = 0

        for term in queryTerms {
            if filename == term {
                score += 60
            }

            if filenameStem == term {
                score += 46
            }

            if filenameExtension == term {
                score += 42
            }

            if lowercasedPath.contains(term) {
                score += 12
            } else if tokens.contains(where: { isFuzzyMatch(term, candidate: $0) }) {
                score += 8
            }
        }

        return score
    }

    private static func pathTokens(from path: String) -> [String] {
        path
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func isFuzzyMatch(_ term: String, candidate: String) -> Bool {
        guard term.count >= 4,
              candidate.count >= 4,
              term.first == candidate.first else {
            return false
        }

        let distance = editDistance(term, candidate, maximumDistance: 2)
        return distance <= 2
    }

    private static func editDistance(_ left: String, _ right: String, maximumDistance: Int) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)

        if abs(leftCharacters.count - rightCharacters.count) > maximumDistance {
            return maximumDistance + 1
        }

        var previousRow = Array(0...rightCharacters.count)

        for (leftIndex, leftCharacter) in leftCharacters.enumerated() {
            var currentRow = [leftIndex + 1]
            var bestInRow = currentRow[0]

            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                let insertion = currentRow[rightIndex] + 1
                let deletion = previousRow[rightIndex + 1] + 1
                let substitution = previousRow[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                currentRow.append(value)
                bestInRow = min(bestInRow, value)
            }

            if bestInRow > maximumDistance {
                return maximumDistance + 1
            }

            previousRow = currentRow
        }

        return previousRow.last ?? maximumDistance + 1
    }

    private static func relevanceScore(
        relativePath: String,
        text: String,
        queryTerms: [String],
        pathScore: Int
    ) -> Int {
        guard !queryTerms.isEmpty else {
            return 1
        }

        let lowercasedText = text.lowercased()
        var score = pathScore

        for term in queryTerms {
            if lowercasedText.contains(term) {
                score += 4
            }
        }

        return score
    }

    private static func pathOnlySnippet(
        relativePath: String,
        kind: String,
        size: Int?,
        modifiedAt: Date?
    ) -> String {
        var lines = [
            "Path: \(relativePath)",
            "Kind: \(kind)"
        ]

        if let size {
            lines.append("Size: \(size) bytes")
        }

        if let modifiedAt {
            lines.append("Modified: \(modifiedAt.formatted(date: .numeric, time: .standard))")
        }

        lines.append("Content was not included; this entry is provided so the AI can answer file location questions.")
        return lines.joined(separator: "\n")
    }

    private static func snippet(from text: String, queryTerms: [String]) -> String {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lowercasedText = normalizedText.lowercased()
        let matchRange = queryTerms
            .compactMap { lowercasedText.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }

        guard let matchRange else {
            return String(normalizedText.prefix(1_200))
        }

        let start = normalizedText.index(matchRange.lowerBound, offsetBy: -400, limitedBy: normalizedText.startIndex)
            ?? normalizedText.startIndex
        let end = normalizedText.index(matchRange.upperBound, offsetBy: 800, limitedBy: normalizedText.endIndex)
            ?? normalizedText.endIndex

        return String(normalizedText[start..<end])
    }

    private static func matchSummary(relativePath: String, text: String, queryTerms: [String]) -> String {
        guard !queryTerms.isEmpty else {
            return "Context candidate"
        }

        let lowercasedPath = relativePath.lowercased()
        let lowercasedText = text.lowercased()
        var matches: [String] = []

        if queryTerms.contains(where: { lowercasedPath.contains($0) }) {
            matches.append("path")
        }

        if queryTerms.contains(where: { lowercasedText.contains($0) }) {
            matches.append("content")
        }

        return matches.isEmpty ? "context candidate" : "matched " + matches.joined(separator: ", ")
    }
}

private extension String {
    var aiNilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var aiTrimmingTrailingSlash: String {
        var result = self

        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }
}

private extension Array where Element: Hashable {
    func aiUniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum AIChatClient {
    struct ChatMessage: Codable, Sendable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        struct ErrorBody: Decodable {
            let message: String?
        }

        let choices: [Choice]?
        let error: ErrorBody?
    }

    static func complete(
        settings: AISearchSettings,
        apiKey: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let normalizedSettings = settings.normalized
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedSettings.endpointURLString.isEmpty,
              !normalizedSettings.model.isEmpty,
              !trimmedAPIKey.isEmpty else {
            throw AISearchError.missingProviderConfiguration
        }

        guard let endpointURL = URL(string: normalizedSettings.endpointURLString) else {
            throw AISearchError.invalidEndpoint(normalizedSettings.endpointURLString)
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: normalizedSettings.model,
                messages: messages,
                temperature: 0.2
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decodedResponse = try? JSONDecoder().decode(ResponseBody.self, from: data)

        guard (200..<300).contains(statusCode) else {
            let responseText = decodedResponse?.error?.message
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(statusCode)"
            throw AISearchError.providerError(responseText)
        }

        guard let content = decodedResponse?.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AISearchError.providerError("AI provider returned an empty response.")
        }

        return content
    }
}

enum AISearchPromptBuilder {
    static func messages(
        question: String,
        contextResult: AIContextBuildResult,
        previousMessages: [AIChatMessage],
        settings: AISearchSettings
    ) -> [AIChatClient.ChatMessage] {
        let systemPrompt = """
        You are Shodana's AI search assistant. Answer the latest user question directly using only the file context explicitly provided by Shodana.

        If the user asks where a file or code is located, answer with the exact full path shown in the context. Never invent placeholder paths such as /path/to/your/project, /your/project, or <project-root>. If the exact full path is not present in the context, say that the full path is not available.

        If the user asks what an app, folder, file, or code does, synthesize an explanation from the disclosed snippets. Do not answer only by listing paths or saying where information may be found. Use paths only as supporting evidence.

        Use conversation history to resolve references such as "the second path", "that folder", or "the previous result", but do not repeat a previous answer unless the latest question asks for it. If the user only says thanks, praise, or a short acknowledgement, respond conversationally and do not repeat the previous file-location answer. Ignore placeholder paths that may appear in earlier assistant messages. Prefer concise, actionable engineering guidance.
        """
        let context = contextText(
            from: contextResult,
            limit: settings.normalized.maxContextCharacters,
            question: question
        )
        let recentHistory = previousMessages
            .suffix(8)
            .map {
                AIChatClient.ChatMessage(
                    role: $0.role.rawValue,
                    content: $0.content
                )
            }
        let currentQuestion = """
        Latest user question. Answer this question, not an earlier one:
        \(question)

        Files disclosed to AI for this turn:
        \(context)
        """

        return [AIChatClient.ChatMessage(role: "system", content: systemPrompt)]
            + recentHistory
            + [AIChatClient.ChatMessage(role: "user", content: currentQuestion)]
    }

    static func contextText(from contextResult: AIContextBuildResult, limit: Int, question: String) -> String {
        let files = contextResult.files

        guard !files.isEmpty || !contextResult.matchingPaths.isEmpty else {
            return "(No files matched the current AI scope and question.)"
        }

        var remainingCharacters = limit
        var chunks: [String] = []
        let shouldIncludePathIndex = shouldIncludePathIndex(for: question) || files.isEmpty

        if shouldIncludePathIndex, !contextResult.matchingPaths.isEmpty {
            let pathIndex = contextResult.matchingPaths
                .map { "- \($0)" }
                .joined(separator: "\n")
            let chunk = """

            --- MATCHING PATH INDEX ---
            These paths matched the user's question. Use this index for file location questions even when the file content is not included below.
            \(pathIndex)
            ---

            """
            chunks.append(String(chunk.prefix(remainingCharacters)))
            remainingCharacters -= min(remainingCharacters, chunk.count)
        }

        for file in files {
            guard remainingCharacters > 0 else {
                break
            }

            let header = """

            --- FILE: \(file.relativePath)
            Full path: \(file.url.path)
            Root path: \(file.rootURL.path)
            Size: \(file.size) bytes
            Match: \(file.matchSummary)
            ---

            """
            let allowedSnippetCount = max(0, remainingCharacters - header.count)
            let snippet = String(file.snippet.prefix(allowedSnippetCount))
            let chunk = header + snippet
            chunks.append(chunk)
            remainingCharacters -= chunk.count
        }

        return chunks.joined(separator: "\n")
    }

    private static func shouldIncludePathIndex(for question: String) -> Bool {
        let lowercasedQuestion = question.lowercased()
        let explanationTokens = [
            "どんな", "働き", "概要", "説明", "教えて", "おしえて", "何を", "なにを",
            "どういう", "どのよう", "what", "explain", "describe", "summary", "overview"
        ]

        if explanationTokens.contains(where: { lowercasedQuestion.contains($0) }) {
            return false
        }

        let locationTokens = [
            "どこ", "場所", "パス", "フルパス", "所在", "開く", "path", "where", "location"
        ]

        return locationTokens.contains { lowercasedQuestion.contains($0) }
    }
}
