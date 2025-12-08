import Foundation

// Note: The core BackupJob struct and BackupJobStatus enum are defined in Tracker.swift
// This file provides extensions and additional functionality for backup job management

/// Priority constants for backup jobs
/// Lower number = higher priority (executed first)
public enum BackupJobPriority {
    /// Library directory - largest, most important (priority 1)
    public static let library = 1
    /// Upload directory - new files being imported (priority 2)
    public static let upload = 2
    /// Profile directory - user profile data (priority 3)
    public static let profile = 3
    /// Backups directory - Immich database backups (priority 4)
    public static let backups = 4
    /// DAM data directory - local tracker data (priority 5)
    public static let damData = 5

    /// Get priority for a given source path
    public static func forPath(_ path: String) -> Int {
        let normalizedPath = path.lowercased()

        if normalizedPath.contains("/library") {
            return library
        } else if normalizedPath.contains("/upload") {
            return upload
        } else if normalizedPath.contains("/profile") {
            return profile
        } else if normalizedPath.contains("/backups") {
            return backups
        } else if normalizedPath.contains("dam/data") || normalizedPath.contains("dam\\data") {
            return damData
        } else {
            // Default priority for unknown paths
            return 99
        }
    }
}

/// Extension to add convenience methods to BackupJob
extension Tracker.BackupJob {
    /// Check if the job is in a terminal state (completed or max retries exceeded)
    public func isTerminal(maxRetries: Int) -> Bool {
        return status == .completed ||
               (status == .failed && retryCount >= maxRetries)
    }

    /// Check if the job can be resumed
    public var canResume: Bool {
        return status == .interrupted || status == .pending
    }

    /// Check if the job needs to be retried
    public func needsRetry(maxRetries: Int) -> Bool {
        return status == .failed && retryCount < maxRetries
    }

    /// Formatted progress percentage
    public var progressPercentage: Double {
        guard bytesTotal > 0 else { return 0.0 }
        return Double(bytesTransferred) / Double(bytesTotal) * 100.0
    }

    /// Human-readable status description
    public var statusDescription: String {
        switch status {
        case .pending:
            return "Waiting to start"
        case .running:
            let percent = String(format: "%.1f", progressPercentage)
            return "Running (\(percent)%)"
        case .completed:
            return "Completed"
        case .interrupted:
            return "Interrupted - will resume"
        case .failed:
            if let error = errorMessage {
                return "Failed: \(error)"
            }
            return "Failed"
        }
    }

    /// Format bytes transferred as human-readable string
    public var formattedBytesTransferred: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesTransferred)
    }

    /// Format total bytes as human-readable string
    public var formattedBytesTotal: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesTotal)
    }

    /// Format transfer speed as human-readable string
    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: transferSpeed))/s"
    }

    /// Duration since job started (if running or completed)
    public var duration: TimeInterval? {
        guard let started = startedAt else { return nil }
        let endTime = completedAt ?? Date()
        return endTime.timeIntervalSince(started)
    }

    /// Formatted duration string
    public var formattedDuration: String {
        guard let duration = duration else { return "-" }

        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return "\(seconds)s"
        }
    }

    /// Get the directory name from source path (for display)
    public var sourceDirectoryName: String {
        let url = URL(fileURLWithPath: sourcePath)
        return url.lastPathComponent
    }
}

/// Status summary for a backup destination
public struct BackupStatus: Sendable {
    public let destinationId: Int64
    public let destinationName: String
    public let lastBackupAt: Date?
    public let totalJobs: Int
    public let pendingJobs: Int
    public let runningJobs: Int
    public let completedJobs: Int
    public let failedJobs: Int
    public let interruptedJobs: Int
    public let totalBytesTransferred: Int64
    public let totalFilesTransferred: Int64
    public let currentJob: Tracker.BackupJob?

    public init(
        destinationId: Int64,
        destinationName: String,
        lastBackupAt: Date?,
        totalJobs: Int,
        pendingJobs: Int,
        runningJobs: Int,
        completedJobs: Int,
        failedJobs: Int,
        interruptedJobs: Int,
        totalBytesTransferred: Int64,
        totalFilesTransferred: Int64,
        currentJob: Tracker.BackupJob?
    ) {
        self.destinationId = destinationId
        self.destinationName = destinationName
        self.lastBackupAt = lastBackupAt
        self.totalJobs = totalJobs
        self.pendingJobs = pendingJobs
        self.runningJobs = runningJobs
        self.completedJobs = completedJobs
        self.failedJobs = failedJobs
        self.interruptedJobs = interruptedJobs
        self.totalBytesTransferred = totalBytesTransferred
        self.totalFilesTransferred = totalFilesTransferred
        self.currentJob = currentJob
    }

    /// Overall completion percentage
    public var completionPercentage: Double {
        guard totalJobs > 0 else { return 0.0 }
        return Double(completedJobs) / Double(totalJobs) * 100.0
    }

    /// Check if backup is currently running
    public var isRunning: Bool {
        return runningJobs > 0
    }

    /// Check if all jobs are complete
    public var isComplete: Bool {
        return totalJobs > 0 && completedJobs == totalJobs
    }

    /// Check if there are any problems (failed or interrupted jobs)
    public var hasProblems: Bool {
        return failedJobs > 0 || interruptedJobs > 0
    }

    /// Human-readable overall status
    public var overallStatus: String {
        if totalJobs == 0 {
            return "No backup jobs"
        } else if isComplete {
            return "All backups complete"
        } else if isRunning {
            return "Backup in progress"
        } else if failedJobs > 0 {
            return "\(failedJobs) job(s) failed"
        } else if interruptedJobs > 0 {
            return "\(interruptedJobs) job(s) interrupted"
        } else if pendingJobs > 0 {
            return "\(pendingJobs) job(s) pending"
        } else {
            return "Unknown status"
        }
    }

    /// Formatted total bytes transferred
    public var formattedTotalBytesTransferred: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytesTransferred)
    }

    /// Formatted last backup time
    public var formattedLastBackupAt: String {
        guard let lastBackup = lastBackupAt else {
            return "Never"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastBackup, relativeTo: Date())
    }
}
