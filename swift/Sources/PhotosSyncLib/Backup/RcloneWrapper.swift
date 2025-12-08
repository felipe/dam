import Foundation

/// Wrapper for rclone CLI operations
public actor RcloneWrapper {
    /// Default rclone executable path
    private let rclonePath: String

    public init(rclonePath: String = "rclone") {
        self.rclonePath = rclonePath
    }

    // MARK: - Installation Check

    /// Check if rclone is installed and available
    public func checkInstalled() async -> Bool {
        do {
            let (_, exitCode) = try await runCommand("/usr/bin/which", arguments: ["rclone"])
            return exitCode == 0
        } catch {
            return false
        }
    }

    /// Get rclone version string
    public func getVersion() async throws -> String {
        let (output, exitCode) = try await runCommand(rclonePath, arguments: ["version"])
        guard exitCode == 0 else {
            throw BackupError.rcloneConfigFailed("Failed to get rclone version")
        }
        // First line contains version
        return output.components(separatedBy: .newlines).first ?? output
    }

    // MARK: - Remote Configuration

    /// Configure an rclone remote
    /// - Parameters:
    ///   - name: Name for the remote
    ///   - type: Remote type (e.g., "b2", "s3", "crypt")
    ///   - config: Configuration key-value pairs
    public func configureRemote(name: String, type: String, config: [String: String]) async throws {
        // Build rclone config arguments
        // rclone config create <name> <type> [option]...
        var arguments = ["config", "create", name, type]

        for (key, value) in config {
            arguments.append("\(key)=\(value)")
        }

        let (output, exitCode) = try await runCommand(rclonePath, arguments: arguments)
        guard exitCode == 0 else {
            throw BackupError.rcloneConfigFailed("Failed to configure remote '\(name)': \(output)")
        }
    }

    /// Delete an rclone remote configuration
    public func deleteRemote(name: String) async throws {
        let (output, exitCode) = try await runCommand(rclonePath, arguments: ["config", "delete", name])
        guard exitCode == 0 else {
            throw BackupError.rcloneConfigFailed("Failed to delete remote '\(name)': \(output)")
        }
    }

    /// List configured remotes
    public func listRemotes() async throws -> [String] {
        let (output, exitCode) = try await runCommand(rclonePath, arguments: ["listremotes"])
        guard exitCode == 0 else {
            throw BackupError.rcloneConfigFailed("Failed to list remotes: \(output)")
        }

        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "") }
            .filter { !$0.isEmpty }
    }

    // MARK: - Connection Testing

    /// Test connection to a remote
    public func testConnection(remote: String) async throws -> Bool {
        // Try to list the root of the remote (limited to 1 item)
        let (_, exitCode) = try await runCommand(
            rclonePath,
            arguments: ["lsf", "\(remote):", "--max-depth", "0"],
            timeout: 30
        )
        return exitCode == 0
    }

    /// Test by writing a small test file
    public func testWrite(remote: String, testContent: String = "test") async throws -> Bool {
        let testFileName = ".rclone_test_\(UUID().uuidString)"

        // Create a temporary local file
        let tempDir = FileManager.default.temporaryDirectory
        let localFile = tempDir.appendingPathComponent(testFileName)

        try testContent.write(to: localFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localFile) }

        // Upload the test file
        let (uploadOutput, uploadCode) = try await runCommand(
            rclonePath,
            arguments: ["copyto", localFile.path, "\(remote):\(testFileName)"],
            timeout: 60
        )

        guard uploadCode == 0 else {
            throw BackupError.rcloneTestFailed("Failed to upload test file: \(uploadOutput)")
        }

        // Verify the file exists
        let (_, verifyCode) = try await runCommand(
            rclonePath,
            arguments: ["lsf", "\(remote):\(testFileName)"],
            timeout: 30
        )

        // Clean up the test file
        _ = try? await runCommand(
            rclonePath,
            arguments: ["deletefile", "\(remote):\(testFileName)"],
            timeout: 30
        )

        return verifyCode == 0
    }

    // MARK: - Sync Operations

    /// Build command arguments for rclone sync
    public func buildSyncCommand(
        source: String,
        destination: String,
        dryRun: Bool = false,
        statsInterval: Int = 60
    ) -> [String] {
        var arguments = ["sync", source, destination]

        // Progress reporting
        arguments.append(contentsOf: ["--stats", "\(statsInterval)s"])
        arguments.append("--stats-one-line")
        arguments.append("--progress")

        // Use JSON log format for easier parsing
        arguments.append("--use-json-log")

        // Verbose logging
        arguments.append("-v")

        // Dry run mode
        if dryRun {
            arguments.append("--dry-run")
        }

        return arguments
    }

    /// Run rclone sync and stream progress updates
    /// - Parameters:
    ///   - source: Source path or remote
    ///   - destination: Destination remote
    ///   - dryRun: If true, don't actually transfer files
    ///   - statsInterval: How often to report stats (seconds)
    /// - Returns: AsyncStream of progress updates
    public func sync(
        source: String,
        destination: String,
        dryRun: Bool = false,
        statsInterval: Int = 60
    ) async throws -> AsyncThrowingStream<SyncProgress, Error> {
        let arguments = buildSyncCommand(
            source: source,
            destination: destination,
            dryRun: dryRun,
            statsInterval: statsInterval
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runSyncWithProgress(
                        arguments: arguments,
                        onProgress: { progress in
                            continuation.yield(progress)
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Run sync command with progress callback
    private func runSyncWithProgress(
        arguments: [String],
        onProgress: @Sendable @escaping (SyncProgress) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [rclonePath] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Read stderr for progress (rclone outputs stats to stderr)
        let errorHandle = errorPipe.fileHandleForReading

        // Process output in a task
        let readTask = Task {
            var buffer = ""

            while process.isRunning || errorHandle.availableData.count > 0 {
                if let data = try? errorHandle.availableData, data.count > 0,
                   let output = String(data: data, encoding: .utf8) {
                    buffer += output

                    // Process complete lines
                    let lines = buffer.components(separatedBy: .newlines)
                    for line in lines.dropLast() {
                        if let progress = SyncProgress.parse(from: line) {
                            onProgress(progress)
                        } else if let progress = SyncProgress.parseTextLine(line) {
                            onProgress(progress)
                        }
                    }
                    buffer = lines.last ?? ""
                }

                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
        }

        process.waitUntilExit()
        readTask.cancel()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw BackupError.rcloneSyncFailed(errorOutput)
        }
    }

    // MARK: - Private Helpers

    private func runCommand(
        _ command: String,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Set up timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return (output + errorOutput, process.terminationStatus)
    }
}
