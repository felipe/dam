import Foundation

/// Orchestrates backup job execution
/// Manages job creation, execution order, progress tracking, and recovery
public actor BackupManager {
    private let tracker: Tracker
    private let staleThresholdSeconds: Int
    private let maxRetries: Int
    private let logPath: URL?
    private var logFileHandle: FileHandle?

    /// Initialize the backup manager
    /// - Parameters:
    ///   - tracker: Database tracker for job persistence
    ///   - staleThresholdSeconds: Time in seconds after which a running job is considered stale (default 60)
    ///   - maxRetries: Maximum number of retries for failed jobs (default 3)
    ///   - logPath: Path to backup.log file (optional)
    public init(
        tracker: Tracker,
        staleThresholdSeconds: Int = 60,
        maxRetries: Int = 3,
        logPath: URL? = nil
    ) {
        self.tracker = tracker
        self.staleThresholdSeconds = staleThresholdSeconds
        self.maxRetries = maxRetries
        self.logPath = logPath
    }

    // MARK: - Job Creation

    /// Create backup jobs for the given source paths
    /// - Parameters:
    ///   - paths: Array of source directory paths to backup
    ///   - destinationId: ID of the backup destination
    /// - Returns: Array of created backup jobs
    public func createJobsForSource(
        paths: [String],
        destinationId: Int64
    ) throws -> [Tracker.BackupJob] {
        var createdJobs: [Tracker.BackupJob] = []

        for (index, path) in paths.enumerated() {
            let priority = index + 1  // 1-indexed priority based on order

            let jobId = try tracker.createBackupJob(
                destinationId: destinationId,
                sourcePath: path,
                priority: priority
            )

            if let job = tracker.getBackupJob(id: jobId) {
                createdJobs.append(job)
            }
        }

        return createdJobs
    }

    /// Get jobs that need to be executed (pending, interrupted, or retryable failed)
    public func getJobsToExecute(destinationId: Int64) -> [Tracker.BackupJob] {
        let allJobs = tracker.getBackupJobs(destinationId: destinationId)

        return allJobs.filter { job in
            switch job.status {
            case .pending:
                return true
            case .interrupted:
                return true
            case .failed:
                return job.retryCount < maxRetries
            case .running, .completed:
                return false
            }
        }
    }

    /// Get jobs that are interrupted and can be resumed
    public func getJobsToResume(destinationId: Int64) -> [Tracker.BackupJob] {
        let allJobs = tracker.getBackupJobs(destinationId: destinationId)
        return allJobs.filter { $0.status == .interrupted }
    }

    // MARK: - Job Execution

    /// Run backup for a destination
    /// - Parameters:
    ///   - destination: The backup destination implementation
    ///   - destinationId: ID of the destination in the database
    ///   - dryRun: If true, don't actually transfer files
    ///   - force: If true, ignore stale job detection
    public func runBackup(
        destination: any BackupDestinationProtocol,
        destinationId: Int64,
        dryRun: Bool = false,
        force: Bool = false
    ) async throws {
        // Initialize logging
        initializeLogging()
        log("Starting backup to destination: \(destination.name)")
        log("Dry run: \(dryRun), Force: \(force)")

        // Check for stale jobs first (unless force is set)
        if !force {
            let staleJobs = tracker.getStaleJobs(thresholdSeconds: staleThresholdSeconds)
            if !staleJobs.isEmpty {
                log("Found \(staleJobs.count) stale job(s), marking as interrupted")
                for job in staleJobs {
                    try tracker.markJobInterrupted(id: job.id)
                    log("  - Marked job \(job.id) (\(job.sourcePath)) as interrupted")
                }
            }
        }

        // Get jobs to execute, sorted by priority
        let jobsToExecute = getJobsToExecute(destinationId: destinationId)

        if jobsToExecute.isEmpty {
            log("No jobs to execute")
            finalizeLogging()
            return
        }

        log("Found \(jobsToExecute.count) job(s) to execute")

        // Execute jobs sequentially by priority
        for job in jobsToExecute {
            log("\nStarting job \(job.id): \(job.sourcePath) (priority \(job.priority))")

            do {
                try await executeJob(
                    job: job,
                    destination: destination,
                    dryRun: dryRun
                )
                log("Job \(job.id) completed successfully")
            } catch {
                log("Job \(job.id) failed: \(error.localizedDescription)")

                // Increment retry count for failed jobs
                try incrementRetryCount(jobId: job.id)

                let updatedJob = tracker.getBackupJob(id: job.id)
                if let retryCount = updatedJob?.retryCount, retryCount >= maxRetries {
                    log("Job \(job.id) exceeded max retries (\(maxRetries)), will not retry")
                } else {
                    log("Job \(job.id) will be retried (attempt \((updatedJob?.retryCount ?? 0) + 1)/\(maxRetries))")
                }
            }
        }

        log("\nBackup run completed")
        finalizeLogging()
    }

    /// Thread-safe progress holder for use in closures
    private final class ProgressHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _progress: SyncProgress?

        var progress: SyncProgress? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _progress
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _progress = newValue
            }
        }
    }

    /// Execute a single backup job
    private func executeJob(
        job: Tracker.BackupJob,
        destination: any BackupDestinationProtocol,
        dryRun: Bool
    ) async throws {
        // Mark job as running
        try tracker.updateBackupJob(
            id: job.id,
            status: .running,
            bytesTotal: job.bytesTotal,
            bytesTransferred: job.bytesTransferred,
            filesTotal: job.filesTotal,
            filesTransferred: job.filesTransferred,
            transferSpeed: 0
        )

        let progressHolder = ProgressHolder()

        do {
            // Run the backup with progress tracking
            try await destination.backup(
                source: job.sourcePath,
                dryRun: dryRun,
                onProgress: { [weak self] progress in
                    guard let self = self else { return }

                    // Store progress in thread-safe holder
                    progressHolder.progress = progress

                    // Update database with progress
                    Task {
                        await self.updateJobProgress(jobId: job.id, progress: progress)
                    }
                }
            )

            // Mark job as completed
            let lastProgress = progressHolder.progress
            let finalBytes = lastProgress?.bytesTransferred ?? job.bytesTransferred
            let finalFiles = lastProgress?.filesTransferred ?? job.filesTransferred

            try tracker.markJobCompleted(
                id: job.id,
                bytesTransferred: finalBytes,
                filesTransferred: finalFiles
            )

        } catch {
            // Mark job as failed
            let lastProgress = progressHolder.progress
            try tracker.updateBackupJob(
                id: job.id,
                status: .failed,
                bytesTotal: lastProgress?.bytesTotal ?? job.bytesTotal,
                bytesTransferred: lastProgress?.bytesTransferred ?? job.bytesTransferred,
                filesTotal: lastProgress?.filesTotal ?? job.filesTotal,
                filesTransferred: lastProgress?.filesTransferred ?? job.filesTransferred,
                transferSpeed: 0,
                errorMessage: error.localizedDescription
            )

            throw error
        }
    }

    /// Update job progress in the database
    private func updateJobProgress(jobId: Int64, progress: SyncProgress) {
        do {
            try tracker.updateBackupJob(
                id: jobId,
                status: .running,
                bytesTotal: progress.bytesTotal,
                bytesTransferred: progress.bytesTransferred,
                filesTotal: progress.filesTotal,
                filesTransferred: progress.filesTransferred,
                transferSpeed: progress.speed
            )
        } catch {
            // Log but don't fail on progress update errors
            log("Warning: Failed to update job progress: \(error.localizedDescription)")
        }
    }

    // MARK: - Stale Job Detection and Recovery

    /// Mark stale jobs as interrupted
    public func markStaleJobsInterrupted() throws {
        let staleJobs = tracker.getStaleJobs(thresholdSeconds: staleThresholdSeconds)

        for job in staleJobs {
            try tracker.markJobInterrupted(id: job.id)
        }
    }

    /// Check if there are any stale jobs
    public func hasStaleJobs() -> Bool {
        return !tracker.getStaleJobs(thresholdSeconds: staleThresholdSeconds).isEmpty
    }

    /// Get list of stale jobs
    public func getStaleJobs() -> [Tracker.BackupJob] {
        return tracker.getStaleJobs(thresholdSeconds: staleThresholdSeconds)
    }

    // MARK: - Retry Logic

    /// Increment the retry count for a job
    public func incrementRetryCount(jobId: Int64) throws {
        try tracker.incrementJobRetryCount(id: jobId)
    }

    /// Check if a job should be retried
    public func shouldRetryJob(jobId: Int64) -> Bool {
        guard let job = tracker.getBackupJob(id: jobId) else { return false }
        return job.status == .failed && job.retryCount < maxRetries
    }

    // MARK: - Status

    /// Get current backup status for a destination
    public func getStatus(destinationId: Int64) -> BackupStatus {
        let destination = tracker.getBackupDestinations().first { $0.id == destinationId }
        let jobs = tracker.getBackupJobs(destinationId: destinationId)
        let activeJob = tracker.getActiveBackupJob(destinationId: destinationId)

        var pendingCount = 0
        var runningCount = 0
        var completedCount = 0
        var failedCount = 0
        var interruptedCount = 0
        var totalBytes: Int64 = 0
        var totalFiles: Int64 = 0

        for job in jobs {
            switch job.status {
            case .pending:
                pendingCount += 1
            case .running:
                runningCount += 1
                totalBytes += job.bytesTransferred
                totalFiles += job.filesTransferred
            case .completed:
                completedCount += 1
                totalBytes += job.bytesTransferred
                totalFiles += job.filesTransferred
            case .failed:
                failedCount += 1
                totalBytes += job.bytesTransferred
                totalFiles += job.filesTransferred
            case .interrupted:
                interruptedCount += 1
                totalBytes += job.bytesTransferred
                totalFiles += job.filesTransferred
            }
        }

        return BackupStatus(
            destinationId: destinationId,
            destinationName: destination?.name ?? "Unknown",
            lastBackupAt: destination?.lastBackupAt,
            totalJobs: jobs.count,
            pendingJobs: pendingCount,
            runningJobs: runningCount,
            completedJobs: completedCount,
            failedJobs: failedCount,
            interruptedJobs: interruptedCount,
            totalBytesTransferred: totalBytes,
            totalFilesTransferred: totalFiles,
            currentJob: activeJob
        )
    }

    /// Get status for all destinations
    public func getAllStatus() -> [BackupStatus] {
        let destinations = tracker.getBackupDestinations()
        return destinations.map { getStatus(destinationId: $0.id) }
    }

    // MARK: - Reset

    /// Reset all jobs for a destination (delete them)
    public func resetJobs(destinationId: Int64) throws {
        try tracker.resetBackupJobs(destinationId: destinationId)
        log("Reset all jobs for destination \(destinationId)")
    }

    // MARK: - Logging

    private func initializeLogging() {
        guard let logPath = logPath else { return }

        // Create or truncate log file
        FileManager.default.createFile(atPath: logPath.path, contents: nil)

        logFileHandle = FileHandle(forWritingAtPath: logPath.path)

        // Write header
        let header = """
        ================================================================================
        Backup Log - \(Date())
        ================================================================================

        """
        writeToLog(header)
    }

    private func finalizeLogging() {
        guard let handle = logFileHandle else { return }

        let footer = """

        ================================================================================
        Backup completed at \(Date())
        ================================================================================
        """
        writeToLog(footer)

        try? handle.close()
        logFileHandle = nil
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)"

        // Always print to console
        print(logLine)

        // Also write to file if logging is enabled
        writeToLog(logLine + "\n")
    }

    private func writeToLog(_ content: String) {
        guard let handle = logFileHandle,
              let data = content.data(using: .utf8) else { return }

        handle.write(data)
    }
}
