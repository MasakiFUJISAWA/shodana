import Foundation

struct SFTPConnectionSpec: Sendable {
    let user: String?
    let host: String
    let port: Int?
    let path: String?

    var target: String {
        if let user, !user.isEmpty {
            return "\(user)@\(host)"
        }

        return host
    }
}

enum SFTPClientError: Error, LocalizedError {
    case invalidURL(URL)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid SFTP URL: \(url.absoluteString)"
        case .commandFailed(let message):
            return message
        }
    }
}

enum SFTPClient {
    private struct ProcessResult: Sendable {
        let status: Int32
        let output: Data
        let errorOutput: Data

        var outputString: String {
            String(data: output, encoding: .utf8) ?? ""
        }

        var errorString: String {
            String(data: errorOutput, encoding: .utf8) ?? ""
        }
    }

    static func isSFTPURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "sftp"
    }

    static func displayString(for url: URL) -> String {
        url.absoluteString.removingPercentEncoding ?? url.absoluteString
    }

    static func url(bySettingPath path: String, on url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "sftp"
        components?.path = normalizedRemotePath(path)
        return components?.url ?? url
    }

    static func childURL(named name: String, in directoryURL: URL) -> URL {
        url(bySettingPath: appendingRemotePathComponent(name, to: remotePath(for: directoryURL)), on: directoryURL)
    }

    static func parentURL(for url: URL) -> URL {
        let path = remotePath(for: url)

        guard path != "/" else {
            return url
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        return Self.url(bySettingPath: parentPath.isEmpty ? "/" : parentPath, on: url)
    }

    static func remotePath(for url: URL) -> String {
        normalizedRemotePath(url.path.isEmpty ? "/" : url.path)
    }

    static func resolvedDirectoryURL(for url: URL) async throws -> URL {
        let spec = try connectionSpec(for: url)

        guard let path = spec.path, !path.isEmpty else {
            return Self.url(bySettingPath: "/", on: url)
        }

        return Self.url(bySettingPath: path, on: url)
    }

    static func listDirectory(at url: URL, showHiddenFiles: Bool) async throws -> (url: URL, items: [FileItem]) {
        let resolvedURL = try await resolvedDirectoryURL(for: url)
        let spec = try connectionSpec(for: resolvedURL)
        let path = spec.path ?? "/"
        let command = """
        set -e
        dir=\(shellQuoted(path))
        if [ ! -d "$dir" ]; then
          echo "Not a directory: $dir" >&2
          exit 72
        fi
        find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\\0%y\\0%s\\0%T@\\0'
        """
        let result = try await runSSH(spec: spec, command: command)
        let items = parseFindOutput(result.output, directoryURL: resolvedURL)
            .filter { showHiddenFiles || !$0.isHidden }

        return (resolvedURL, items)
    }

    static func upload(localURLs: [URL], to remoteDirectoryURL: URL) async throws {
        guard !localURLs.isEmpty else {
            return
        }

        let spec = try connectionSpec(for: remoteDirectoryURL)
        let destinationPath = spec.path ?? "/"
        let batch = localURLs
            .map { "put -r \(sftpQuoted($0.path)) \(sftpQuoted(destinationPath))" }
            .joined(separator: "\n")
            + "\n"

        try await runSFTP(spec: spec, batch: batch)
    }

    static func download(remoteURLs: [URL], to localDirectoryURL: URL) async throws {
        guard !remoteURLs.isEmpty else {
            return
        }

        try FileManager.default.createDirectory(
            at: localDirectoryURL,
            withIntermediateDirectories: true
        )

        let groupedURLs = Dictionary(grouping: remoteURLs) { remoteIdentity(for: $0) }

        for urls in groupedURLs.values {
            guard let firstURL = urls.first else {
                continue
            }

            let spec = try connectionSpec(for: firstURL)
            let batch = urls
                .map { "get -r \(sftpQuoted(remotePath(for: $0))) \(sftpQuoted(localDirectoryURL.path))" }
                .joined(separator: "\n")
                + "\n"

            try await runSFTP(spec: spec, batch: batch)
        }
    }

    static func createDirectory(at url: URL) async throws {
        let spec = try connectionSpec(for: url)
        try await runRemoteMutation(spec: spec, command: "mkdir -- \(shellQuoted(spec.path ?? "/"))")
    }

    static func createFile(at url: URL) async throws {
        let spec = try connectionSpec(for: url)
        try await runRemoteMutation(spec: spec, command: ": > \(shellQuoted(spec.path ?? "/"))")
    }

    static func rename(from sourceURL: URL, to destinationURL: URL) async throws {
        let spec = try connectionSpec(for: sourceURL)
        try await runRemoteMutation(
            spec: spec,
            command: "mv -- \(shellQuoted(remotePath(for: sourceURL))) \(shellQuoted(remotePath(for: destinationURL)))"
        )
    }

    static func duplicate(from sourceURL: URL, to destinationURL: URL) async throws {
        let spec = try connectionSpec(for: sourceURL)
        try await runRemoteMutation(
            spec: spec,
            command: "cp -R -- \(shellQuoted(remotePath(for: sourceURL))) \(shellQuoted(remotePath(for: destinationURL)))"
        )
    }

    static func remove(_ urls: [URL]) async throws {
        let groupedURLs = Dictionary(grouping: urls) { remoteIdentity(for: $0) }

        for urls in groupedURLs.values {
            guard let firstURL = urls.first else {
                continue
            }

            let spec = try connectionSpec(for: firstURL)
            let arguments = urls.map { shellQuoted(remotePath(for: $0)) }.joined(separator: " ")
            try await runRemoteMutation(spec: spec, command: "rm -rf -- \(arguments)")
        }
    }

    static func connectionSpec(for url: URL) throws -> SFTPConnectionSpec {
        guard isSFTPURL(url), let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw SFTPClientError.invalidURL(url)
        }

        let path = url.path.isEmpty ? nil : normalizedRemotePath(url.path)

        return SFTPConnectionSpec(
            user: url.user(percentEncoded: false),
            host: host,
            port: url.port,
            path: path
        )
    }

    private static func parseFindOutput(_ data: Data, directoryURL: URL) -> [FileItem] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
        var items: [FileItem] = []
        var index = 0

        while index + 3 < fields.count {
            defer { index += 4 }

            guard let name = String(data: fields[index], encoding: .utf8),
                  !name.isEmpty,
                  let type = String(data: fields[index + 1], encoding: .utf8) else {
                continue
            }

            let sizeString = String(data: fields[index + 2], encoding: .utf8) ?? ""
            let timestampString = String(data: fields[index + 3], encoding: .utf8) ?? ""
            let isDirectory = type == "d"
            let size = Int64(sizeString)
            let timestamp = TimeInterval(timestampString)
            let modifiedAt = timestamp.map { Date(timeIntervalSince1970: $0) }
            let itemURL = childURL(named: name, in: directoryURL)
            let kind: String

            switch type {
            case "d":
                kind = "Folder"
            case "l":
                kind = "Symbolic Link"
            default:
                kind = "File"
            }

            items.append(
                FileItem(
                    url: itemURL,
                    name: name,
                    isDirectory: isDirectory,
                    isPackage: false,
                    size: isDirectory ? nil : size,
                    modifiedAt: modifiedAt,
                    kind: kind,
                    isHidden: name.hasPrefix(".")
                )
            )
        }

        return items
    }

    private static func runRemoteMutation(spec: SFTPConnectionSpec, command: String) async throws {
        _ = try await runSSH(spec: spec, command: command)
    }

    @discardableResult
    private static func runSSH(spec: SFTPConnectionSpec, command: String) async throws -> ProcessResult {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10"
        ]

        if let port = spec.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }

        arguments.append(contentsOf: [spec.target, command])
        return try await run("/usr/bin/ssh", arguments: arguments)
    }

    private static func runSFTP(spec: SFTPConnectionSpec, batch: String) async throws {
        var arguments = [
            "-b", "-",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10"
        ]

        if let port = spec.port {
            arguments.append(contentsOf: ["-P", String(port)])
        }

        arguments.append(spec.target)
        _ = try await run("/usr/bin/sftp", arguments: arguments, standardInput: Data(batch.utf8))
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            if standardInput != nil {
                process.standardInput = inputPipe
            }

            try process.run()

            if let standardInput {
                inputPipe.fileHandleForWriting.write(standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }

            process.waitUntilExit()

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let result = ProcessResult(
                status: process.terminationStatus,
                output: output,
                errorOutput: errorOutput
            )

            guard result.status == 0 else {
                let message = result.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? "SFTP command failed with status \(result.status)."

                throw SFTPClientError.commandFailed(message)
            }

            return result
        }.value
    }

    private static func remoteIdentity(for url: URL) -> String {
        let user = url.user(percentEncoded: false) ?? ""
        let host = url.host(percentEncoded: false) ?? ""
        let port = url.port.map(String.init) ?? ""
        return "\(user)@\(host):\(port)"
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        guard !path.isEmpty else {
            return "/"
        }

        let normalizedPath = (path as NSString).standardizingPath
        return normalizedPath.hasPrefix("/") ? normalizedPath : "/\(normalizedPath)"
    }

    private static func appendingRemotePathComponent(_ component: String, to path: String) -> String {
        if path == "/" {
            return "/\(component)"
        }

        return "\(path)/\(component)"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func sftpQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
