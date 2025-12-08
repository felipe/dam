import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("Backup Manager Tests")
struct BackupManagerSpec {

    // MARK: - Helper to create temp database

    private func createTempTracker() throws -> Tracker {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_backup_\(UUID().uuidString).db")
        return try Tracker(dbPath: dbPath)
    }

    // MARK: - Job Creation Tests

    @Test("Creates jobs for each source directory")
    func jobCreationForSourceDirectories() async throws {
        let tracker = try createTempTracker()

        // Create a test destination
        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create a mock backup manager
        let manager = BackupManager(tracker: tracker)

        // Create jobs for multiple source paths
        let sourcePaths = [
            "/Volumes/BLU2T/immich/library",
            "/Volumes/BLU2T/immich/upload",
            "/Volumes/BLU2T/immich/profile"
        ]

        let jobs = try await manager.createJobsForSource(
            paths: sourcePaths,
            destinationId: destId
        )

        #expect(jobs.count == 3)

        // Verify each job has correct source path
        for (index, job) in jobs.enumerated() {
            #expect(job.sourcePath == sourcePaths[index])
            #expect(job.destinationId == destId)
            #expect(job.status == .pending)
        }
    }

    @Test("Jobs are created with correct priority order")
    func jobPriorityOrder() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker)

        // Source paths in priority order
        let sourcePaths = [
            "/Volumes/BLU2T/immich/library",   // priority 1
            "/Volumes/BLU2T/immich/upload",    // priority 2
            "/Volumes/BLU2T/immich/profile",   // priority 3
            "/Volumes/BLU2T/immich/backups",   // priority 4
            "/Users/felipe/dam/data"           // priority 5
        ]

        let jobs = try await manager.createJobsForSource(
            paths: sourcePaths,
            destinationId: destId
        )

        // Verify priorities are assigned correctly (1-indexed)
        for (index, job) in jobs.enumerated() {
            #expect(job.priority == index + 1)
        }
    }

    @Test("Sequential job execution by priority")
    func sequentialJobExecution() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create jobs out of order to test priority sorting
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/c", priority: 3)
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/a", priority: 1)
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/b", priority: 2)

        // Get jobs - should be sorted by priority
        let jobs = tracker.getBackupJobs(destinationId: destId)

        #expect(jobs.count == 3)
        #expect(jobs[0].sourcePath == "/path/a")
        #expect(jobs[0].priority == 1)
        #expect(jobs[1].sourcePath == "/path/b")
        #expect(jobs[1].priority == 2)
        #expect(jobs[2].sourcePath == "/path/c")
        #expect(jobs[2].priority == 3)
    }

    @Test("Progress tracking updates database")
    func progressTrackingUpdates() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/path",
            priority: 1
        )

        // Update job with progress
        try tracker.updateBackupJob(
            id: jobId,
            status: .running,
            bytesTotal: 1_000_000_000,
            bytesTransferred: 500_000_000,
            filesTotal: 100,
            filesTransferred: 50,
            transferSpeed: 50_000_000
        )

        // Verify the update
        let job = tracker.getBackupJob(id: jobId)

        #expect(job != nil)
        #expect(job?.status == .running)
        #expect(job?.bytesTotal == 1_000_000_000)
        #expect(job?.bytesTransferred == 500_000_000)
        #expect(job?.filesTotal == 100)
        #expect(job?.filesTransferred == 50)
        #expect(job?.transferSpeed == 50_000_000)
    }

    @Test("Stale job detection marks jobs as INTERRUPTED")
    func staleJobDetection() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker, staleThresholdSeconds: 60)

        // Create a running job
        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/path",
            priority: 1
        )

        // Manually mark it as running
        try tracker.updateBackupJob(
            id: jobId,
            status: .running,
            bytesTotal: 1000,
            bytesTransferred: 500,
            filesTotal: 10,
            filesTransferred: 5,
            transferSpeed: 100
        )

        // Immediately check - should not be stale (last_update is now)
        let staleJobs = tracker.getStaleJobs(thresholdSeconds: 60)
        #expect(staleJobs.isEmpty)

        // Mark stale jobs as interrupted
        try await manager.markStaleJobsInterrupted()

        // Job should still be running since it was just updated
        let job = tracker.getBackupJob(id: jobId)
        #expect(job?.status == .running)
    }

    @Test("Resume behavior for interrupted jobs")
    func resumeInterruptedJobs() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create an interrupted job
        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/path",
            priority: 1
        )

        try tracker.updateBackupJob(
            id: jobId,
            status: .running,
            bytesTotal: 1000,
            bytesTransferred: 500,
            filesTotal: 10,
            filesTransferred: 5,
            transferSpeed: 100
        )

        try tracker.markJobInterrupted(id: jobId)

        // Verify job is interrupted
        let interruptedJob = tracker.getBackupJob(id: jobId)
        #expect(interruptedJob?.status == .interrupted)

        let manager = BackupManager(tracker: tracker)

        // Get jobs that need to be resumed
        let jobsToResume = await manager.getJobsToResume(destinationId: destId)

        #expect(jobsToResume.count == 1)
        #expect(jobsToResume.first?.id == jobId)
        #expect(jobsToResume.first?.status == .interrupted)
    }

    @Test("Retry logic for failed jobs")
    func retryFailedJobs() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker, maxRetries: 3)

        // Create a job
        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/path",
            priority: 1
        )

        // Mark it as failed with error
        try tracker.updateBackupJob(
            id: jobId,
            status: .failed,
            bytesTotal: 1000,
            bytesTransferred: 0,
            filesTotal: 10,
            filesTransferred: 0,
            transferSpeed: 0,
            errorMessage: "Network error"
        )

        // Increment retry count
        try await manager.incrementRetryCount(jobId: jobId)

        let job = tracker.getBackupJob(id: jobId)
        #expect(job?.retryCount == 1)

        // Check if job should be retried
        let shouldRetry = await manager.shouldRetryJob(jobId: jobId)
        #expect(shouldRetry == true)

        // Increment past max retries
        try await manager.incrementRetryCount(jobId: jobId)
        try await manager.incrementRetryCount(jobId: jobId)
        try await manager.incrementRetryCount(jobId: jobId)

        let shouldRetryAgain = await manager.shouldRetryJob(jobId: jobId)
        #expect(shouldRetryAgain == false)
    }

    // MARK: - BackupStatus Tests

    @Test("Gets correct backup status")
    func backupStatusRetrieval() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create some jobs with various states
        let job1Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/1", priority: 1)
        let job2Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/2", priority: 2)
        let job3Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/3", priority: 3)

        // Complete first job
        try tracker.markJobCompleted(id: job1Id, bytesTransferred: 1000, filesTransferred: 10)

        // Mark second job as running
        try tracker.updateBackupJob(
            id: job2Id,
            status: .running,
            bytesTotal: 5000,
            bytesTransferred: 2500,
            filesTotal: 50,
            filesTransferred: 25,
            transferSpeed: 100
        )

        // Third job stays pending

        let manager = BackupManager(tracker: tracker)
        let status = await manager.getStatus(destinationId: destId)

        #expect(status.totalJobs == 3)
        #expect(status.completedJobs == 1)
        #expect(status.runningJobs == 1)
        #expect(status.pendingJobs == 1)
        #expect(status.failedJobs == 0)
        #expect(status.totalBytesTransferred == 3500) // 1000 + 2500
    }
}
