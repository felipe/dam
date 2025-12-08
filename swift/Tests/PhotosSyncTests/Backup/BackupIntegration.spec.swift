import Testing
import Foundation
@testable import PhotosSyncLib

/// Strategic integration tests covering backup workflows not tested elsewhere
@Suite("Backup Integration Tests")
struct BackupIntegrationSpec {

    // MARK: - Helper to create temp database

    private func createTempTracker() throws -> Tracker {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_backup_int_\(UUID().uuidString).db")
        return try Tracker(dbPath: dbPath)
    }

    // MARK: - Test 1: Full backup workflow simulation (setup -> backup -> status)

    @Test("Full backup workflow from setup to status")
    func fullBackupWorkflow() async throws {
        let tracker = try createTempTracker()

        // Step 1: Setup - Create destination
        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Verify destination was created
        let destination = tracker.getBackupDestination(name: "b2")
        #expect(destination != nil)
        #expect(destination?.id == destId)

        // Step 2: Create jobs (simulating what happens after setup)
        let manager = BackupManager(tracker: tracker, maxRetries: 3)
        let sourcePaths = ["/test/library", "/test/upload", "/test/profile"]
        let jobs = try await manager.createJobsForSource(paths: sourcePaths, destinationId: destId)
        #expect(jobs.count == 3)

        // Step 3: Simulate running and completing first job
        try tracker.updateBackupJob(
            id: jobs[0].id,
            status: .running,
            bytesTotal: 1000,
            bytesTransferred: 500,
            filesTotal: 10,
            filesTransferred: 5,
            transferSpeed: 100
        )

        // Complete the job
        try tracker.markJobCompleted(id: jobs[0].id, bytesTransferred: 1000, filesTransferred: 10)

        // Step 4: Check status reflects the progress
        let status = await manager.getStatus(destinationId: destId)
        #expect(status.totalJobs == 3)
        #expect(status.completedJobs == 1)
        #expect(status.pendingJobs == 2)
        #expect(status.totalBytesTransferred == 1000)
        #expect(!status.isComplete)
        #expect(!status.isRunning)
    }

    // MARK: - Test 2: Interrupted backup resume simulation

    @Test("Interrupted backup resume simulation")
    func interruptedBackupResume() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker, maxRetries: 3)

        // Create jobs
        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/library",
            priority: 1
        )

        // Simulate partial progress before interruption
        try tracker.updateBackupJob(
            id: jobId,
            status: .running,
            bytesTotal: 10_000_000,  // 10MB total
            bytesTransferred: 4_500_000,  // 4.5MB transferred
            filesTotal: 1000,
            filesTransferred: 450,
            transferSpeed: 1_000_000
        )

        // Simulate interruption
        try tracker.markJobInterrupted(id: jobId)

        // Verify job is interrupted
        let interruptedJob = tracker.getBackupJob(id: jobId)
        #expect(interruptedJob?.status == .interrupted)
        #expect(interruptedJob?.bytesTransferred == 4_500_000)

        // Get jobs to resume - interrupted job should be returned
        let jobsToResume = await manager.getJobsToResume(destinationId: destId)
        #expect(jobsToResume.count == 1)
        #expect(jobsToResume.first?.id == jobId)

        // Get jobs to execute - should include interrupted job
        let jobsToExecute = await manager.getJobsToExecute(destinationId: destId)
        #expect(jobsToExecute.contains { $0.id == jobId })

        // Simulate resume completion
        try tracker.markJobCompleted(id: jobId, bytesTransferred: 10_000_000, filesTransferred: 1000)

        // Verify job completed
        let completedJob = tracker.getBackupJob(id: jobId)
        #expect(completedJob?.status == .completed)
        #expect(completedJob?.bytesTransferred == 10_000_000)
    }

    // MARK: - Test 3: Multiple destination switching

    @Test("Multiple destination switching")
    func multipleDestinationSwitching() async throws {
        let tracker = try createTempTracker()

        // Create two destinations
        let dest1Id = try tracker.createBackupDestination(
            name: "b2-primary",
            type: "b2",
            bucketName: "primary-bucket",
            remotePath: "/"
        )

        let dest2Id = try tracker.createBackupDestination(
            name: "b2-secondary",
            type: "b2",
            bucketName: "secondary-bucket",
            remotePath: "/"
        )

        // Create jobs for first destination
        _ = try tracker.createBackupJob(destinationId: dest1Id, sourcePath: "/path/a", priority: 1)
        _ = try tracker.createBackupJob(destinationId: dest1Id, sourcePath: "/path/b", priority: 2)

        // Create jobs for second destination
        _ = try tracker.createBackupJob(destinationId: dest2Id, sourcePath: "/path/c", priority: 1)

        // Verify jobs are separated by destination
        let dest1Jobs = tracker.getBackupJobs(destinationId: dest1Id)
        let dest2Jobs = tracker.getBackupJobs(destinationId: dest2Id)

        #expect(dest1Jobs.count == 2)
        #expect(dest2Jobs.count == 1)

        // Verify status is calculated per destination
        let manager = BackupManager(tracker: tracker)

        let status1 = await manager.getStatus(destinationId: dest1Id)
        let status2 = await manager.getStatus(destinationId: dest2Id)

        #expect(status1.totalJobs == 2)
        #expect(status1.destinationName == "b2-primary")

        #expect(status2.totalJobs == 1)
        #expect(status2.destinationName == "b2-secondary")

        // Complete jobs on first destination, second should be unaffected
        try tracker.markJobCompleted(id: dest1Jobs[0].id, bytesTransferred: 1000, filesTransferred: 10)
        try tracker.markJobCompleted(id: dest1Jobs[1].id, bytesTransferred: 2000, filesTransferred: 20)

        let status1Updated = await manager.getStatus(destinationId: dest1Id)
        let status2Updated = await manager.getStatus(destinationId: dest2Id)

        #expect(status1Updated.completedJobs == 2)
        #expect(status1Updated.isComplete)

        #expect(status2Updated.completedJobs == 0)
        #expect(!status2Updated.isComplete)
    }

    // MARK: - Test 4: Error recovery with multiple jobs

    @Test("Error recovery and retry across multiple jobs")
    func errorRecoveryMultipleJobs() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker, maxRetries: 2)

        // Create multiple jobs
        let job1Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/1", priority: 1)
        let job2Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/2", priority: 2)
        let job3Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/3", priority: 3)

        // Simulate first job fails
        try tracker.updateBackupJob(
            id: job1Id,
            status: .failed,
            bytesTotal: 1000,
            bytesTransferred: 100,
            filesTotal: 10,
            filesTransferred: 1,
            transferSpeed: 0,
            errorMessage: "Network timeout"
        )

        // Complete second job successfully
        try tracker.updateBackupJob(
            id: job2Id,
            status: .running,
            bytesTotal: 2000,
            bytesTransferred: 2000,
            filesTotal: 20,
            filesTransferred: 20,
            transferSpeed: 1000
        )
        try tracker.markJobCompleted(id: job2Id, bytesTransferred: 2000, filesTransferred: 20)

        // Third job interrupted
        try tracker.updateBackupJob(
            id: job3Id,
            status: .running,
            bytesTotal: 3000,
            bytesTransferred: 1500,
            filesTotal: 30,
            filesTransferred: 15,
            transferSpeed: 500
        )
        try tracker.markJobInterrupted(id: job3Id)

        // Verify status shows mixed states
        let status = await manager.getStatus(destinationId: destId)
        #expect(status.totalJobs == 3)
        #expect(status.completedJobs == 1)
        #expect(status.failedJobs == 1)
        #expect(status.interruptedJobs == 1)
        #expect(status.hasProblems)

        // Get jobs to execute - should include failed (retry) and interrupted
        let jobsToExecute = await manager.getJobsToExecute(destinationId: destId)
        #expect(jobsToExecute.count == 2)

        // Verify failed job can retry
        #expect(await manager.shouldRetryJob(jobId: job1Id) == true)

        // Increment retry past max
        try await manager.incrementRetryCount(jobId: job1Id)
        try await manager.incrementRetryCount(jobId: job1Id)
        try await manager.incrementRetryCount(jobId: job1Id)

        // Verify failed job no longer included after max retries
        let jobsToExecuteAfter = await manager.getJobsToExecute(destinationId: destId)
        #expect(jobsToExecuteAfter.count == 1)  // Only interrupted job
        #expect(await manager.shouldRetryJob(jobId: job1Id) == false)
    }

    // MARK: - Test 5: BackupStatus computed properties

    @Test("BackupStatus computed properties")
    func backupStatusComputedProperties() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Test empty status
        let manager = BackupManager(tracker: tracker)
        let emptyStatus = await manager.getStatus(destinationId: destId)
        #expect(emptyStatus.totalJobs == 0)
        #expect(emptyStatus.isComplete == false)
        #expect(emptyStatus.isRunning == false)
        #expect(emptyStatus.hasProblems == false)
        #expect(emptyStatus.completionPercentage == 0.0)
        #expect(emptyStatus.overallStatus == "No backup jobs")

        // Create and complete all jobs
        let job1Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/1", priority: 1)
        let job2Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/2", priority: 2)

        try tracker.markJobCompleted(id: job1Id, bytesTransferred: 1000, filesTransferred: 10)
        try tracker.markJobCompleted(id: job2Id, bytesTransferred: 2000, filesTransferred: 20)

        let completeStatus = await manager.getStatus(destinationId: destId)
        #expect(completeStatus.isComplete == true)
        #expect(completeStatus.completionPercentage == 100.0)
        #expect(completeStatus.overallStatus == "All backups complete")

        // Test with running job
        let job3Id = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/3", priority: 3)
        try tracker.updateBackupJob(
            id: job3Id,
            status: .running,
            bytesTotal: 3000,
            bytesTransferred: 1500,
            filesTotal: 30,
            filesTransferred: 15,
            transferSpeed: 500
        )

        let runningStatus = await manager.getStatus(destinationId: destId)
        #expect(runningStatus.isRunning == true)
        #expect(runningStatus.isComplete == false)
        #expect(runningStatus.overallStatus.contains("progress"))
    }

    // MARK: - Test 6: BackupJob extension methods

    @Test("BackupJob extension methods")
    func backupJobExtensionMethods() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/Volumes/Data/immich/library",
            priority: 1
        )

        // Test pending job
        var job = tracker.getBackupJob(id: jobId)!
        #expect(job.canResume == true)
        #expect(job.isTerminal(maxRetries: 3) == false)
        #expect(job.needsRetry(maxRetries: 3) == false)
        #expect(job.progressPercentage == 0.0)
        #expect(job.statusDescription == "Waiting to start")
        #expect(job.sourceDirectoryName == "library")

        // Test running job with progress
        try tracker.updateBackupJob(
            id: jobId,
            status: .running,
            bytesTotal: 1_000_000,
            bytesTransferred: 250_000,
            filesTotal: 100,
            filesTransferred: 25,
            transferSpeed: 50_000
        )

        job = tracker.getBackupJob(id: jobId)!
        #expect(job.canResume == false)
        #expect(job.progressPercentage == 25.0)
        #expect(job.statusDescription.contains("25.0"))
        #expect(job.formattedBytesTransferred.contains("KB") || job.formattedBytesTransferred.contains("250"))
        #expect(job.formattedSpeed.contains("/s"))

        // Test completed job
        try tracker.markJobCompleted(id: jobId, bytesTransferred: 1_000_000, filesTransferred: 100)
        job = tracker.getBackupJob(id: jobId)!
        #expect(job.isTerminal(maxRetries: 3) == true)
        #expect(job.statusDescription == "Completed")

        // Test failed job
        let job2Id = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/Volumes/Data/immich/upload",
            priority: 2
        )
        try tracker.updateBackupJob(
            id: job2Id,
            status: .failed,
            bytesTotal: 500_000,
            bytesTransferred: 0,
            filesTotal: 50,
            filesTransferred: 0,
            transferSpeed: 0,
            errorMessage: "Connection refused"
        )

        var job2 = tracker.getBackupJob(id: job2Id)!
        #expect(job2.needsRetry(maxRetries: 3) == true)
        #expect(job2.isTerminal(maxRetries: 3) == false)
        #expect(job2.statusDescription.contains("Connection refused"))

        // Exhaust retries
        try tracker.incrementJobRetryCount(id: job2Id)
        try tracker.incrementJobRetryCount(id: job2Id)
        try tracker.incrementJobRetryCount(id: job2Id)

        job2 = tracker.getBackupJob(id: job2Id)!
        #expect(job2.needsRetry(maxRetries: 3) == false)
        #expect(job2.isTerminal(maxRetries: 3) == true)
    }

    // MARK: - Test 7: getJobsToExecute with mixed states

    @Test("getJobsToExecute filters correctly with mixed states")
    func getJobsToExecuteMixedStates() async throws {
        let tracker = try createTempTracker()

        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        let manager = BackupManager(tracker: tracker, maxRetries: 2)

        // Create jobs in various states
        let pendingJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/pending", priority: 1)
        let runningJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/running", priority: 2)
        let completedJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/completed", priority: 3)
        let interruptedJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/interrupted", priority: 4)
        let failedRetryableJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/failed-retry", priority: 5)
        let failedMaxedJobId = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/failed-maxed", priority: 6)

        // Set job states
        // pendingJobId stays pending

        try tracker.updateBackupJob(
            id: runningJobId,
            status: .running,
            bytesTotal: 1000,
            bytesTransferred: 500,
            filesTotal: 10,
            filesTransferred: 5,
            transferSpeed: 100
        )

        try tracker.markJobCompleted(id: completedJobId, bytesTransferred: 1000, filesTransferred: 10)

        try tracker.updateBackupJob(
            id: interruptedJobId,
            status: .running,
            bytesTotal: 1000,
            bytesTransferred: 300,
            filesTotal: 10,
            filesTransferred: 3,
            transferSpeed: 50
        )
        try tracker.markJobInterrupted(id: interruptedJobId)

        try tracker.updateBackupJob(
            id: failedRetryableJobId,
            status: .failed,
            bytesTotal: 1000,
            bytesTransferred: 0,
            filesTotal: 10,
            filesTransferred: 0,
            transferSpeed: 0,
            errorMessage: "Error 1"
        )
        // retry_count = 0, can retry

        try tracker.updateBackupJob(
            id: failedMaxedJobId,
            status: .failed,
            bytesTotal: 1000,
            bytesTransferred: 0,
            filesTotal: 10,
            filesTransferred: 0,
            transferSpeed: 0,
            errorMessage: "Error 2"
        )
        // Max out retries
        try tracker.incrementJobRetryCount(id: failedMaxedJobId)
        try tracker.incrementJobRetryCount(id: failedMaxedJobId)
        try tracker.incrementJobRetryCount(id: failedMaxedJobId)

        // Get jobs to execute
        let jobsToExecute = await manager.getJobsToExecute(destinationId: destId)

        // Should include: pending, interrupted, failed-retryable
        // Should exclude: running, completed, failed-maxed
        let jobIds = Set(jobsToExecute.map { $0.id })

        #expect(jobIds.contains(pendingJobId))
        #expect(!jobIds.contains(runningJobId))  // Running jobs not re-executed
        #expect(!jobIds.contains(completedJobId))
        #expect(jobIds.contains(interruptedJobId))
        #expect(jobIds.contains(failedRetryableJobId))
        #expect(!jobIds.contains(failedMaxedJobId))

        #expect(jobsToExecute.count == 3)
    }

    // MARK: - Test 8: BackupJobPriority path detection edge cases

    @Test("BackupJobPriority path detection edge cases")
    func backupJobPriorityEdgeCases() {
        // Test standard paths
        #expect(BackupJobPriority.forPath("/Volumes/Data/immich/library") == 1)
        #expect(BackupJobPriority.forPath("/mnt/immich/library") == 1)
        #expect(BackupJobPriority.forPath("/home/user/immich/upload") == 2)
        #expect(BackupJobPriority.forPath("/var/data/profile") == 3)
        #expect(BackupJobPriority.forPath("/opt/backups") == 4)

        // Test case insensitivity
        #expect(BackupJobPriority.forPath("/DATA/LIBRARY") == 1)
        #expect(BackupJobPriority.forPath("/UPLOAD") == 2)
        #expect(BackupJobPriority.forPath("/Profile") == 3)

        // Test dam/data paths
        #expect(BackupJobPriority.forPath("/Users/felipe/dam/data") == 5)
        #expect(BackupJobPriority.forPath("/home/user/dam/data/tracker.db") == 5)

        // Test unknown paths get default priority
        #expect(BackupJobPriority.forPath("/random/path") == 99)
        #expect(BackupJobPriority.forPath("/some/other/directory") == 99)
        #expect(BackupJobPriority.forPath("") == 99)

        // Test partial matches (should still work)
        #expect(BackupJobPriority.forPath("/deep/nested/library/subdir") == 1)
        #expect(BackupJobPriority.forPath("/some/upload/path") == 2)
    }
}
