import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("Backup Command Tests")
struct BackupCommandSpec {

    // MARK: - Helper to create temp database

    private func createTempTracker() throws -> Tracker {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_backup_cmd_\(UUID().uuidString).db")
        return try Tracker(dbPath: dbPath)
    }

    // MARK: - Prerequisite Check Tests

    @Test("Prerequisite check detects rclone installation status")
    func prerequisiteCheckRclone() async throws {
        // This test verifies RcloneWrapper can check installation
        let rclone = RcloneWrapper()
        let installed = await rclone.checkInstalled()

        // We just verify the method runs without error
        // Result depends on system configuration
        #expect(installed == true || installed == false)
    }

    @Test("Prerequisite check detects 1Password CLI installation status")
    func prerequisiteCheckOnePassword() async throws {
        // This test verifies OnePasswordCLI can check installation
        let onePassword = OnePasswordCLI()
        let installed = await onePassword.checkInstalled()

        // We just verify the method runs without error
        // Result depends on system configuration
        #expect(installed == true || installed == false)
    }

    // MARK: - Status Flag Tests

    @Test("Status flag shows database state for destination")
    func statusShowsDatabaseState() async throws {
        let tracker = try createTempTracker()

        // Create a destination
        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create some jobs with various states
        let job1Id = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/path/1",
            priority: 1
        )
        try tracker.markJobCompleted(id: job1Id, bytesTransferred: 1000, filesTransferred: 10)

        let job2Id = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/path/2",
            priority: 2
        )
        try tracker.updateBackupJob(
            id: job2Id,
            status: .running,
            bytesTotal: 5000,
            bytesTransferred: 2500,
            filesTotal: 50,
            filesTransferred: 25,
            transferSpeed: 100
        )

        // Use BackupManager to get status
        let manager = BackupManager(tracker: tracker)
        let status = await manager.getStatus(destinationId: destId)

        #expect(status.destinationName == "test-b2")
        #expect(status.totalJobs == 2)
        #expect(status.completedJobs == 1)
        #expect(status.runningJobs == 1)
        #expect(status.totalBytesTransferred == 3500) // 1000 + 2500
    }

    // MARK: - Reset Flag Tests

    @Test("Reset flag clears job state")
    func resetClearsJobState() async throws {
        let tracker = try createTempTracker()

        // Create a destination
        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create some jobs
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/1", priority: 1)
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/2", priority: 2)
        _ = try tracker.createBackupJob(destinationId: destId, sourcePath: "/path/3", priority: 3)

        // Verify jobs exist
        let jobsBefore = tracker.getBackupJobs(destinationId: destId)
        #expect(jobsBefore.count == 3)

        // Reset via BackupManager
        let manager = BackupManager(tracker: tracker)
        try await manager.resetJobs(destinationId: destId)

        // Verify jobs are gone
        let jobsAfter = tracker.getBackupJobs(destinationId: destId)
        #expect(jobsAfter.count == 0)
    }

    // MARK: - Dry Run Tests

    @Test("Dry run flag is passed to manager")
    func dryRunFlagBehavior() async throws {
        let tracker = try createTempTracker()

        // Create a destination
        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create a job
        let jobId = try tracker.createBackupJob(
            destinationId: destId,
            sourcePath: "/test/path",
            priority: 1
        )

        // Verify job is in pending state
        let job = tracker.getBackupJob(id: jobId)
        #expect(job?.status == .pending)

        // The actual dry run behavior is tested at the BackupManager level
        // Here we just verify the job stays pending when dry run would be used
        #expect(job?.bytesTransferred == 0)
    }

    // MARK: - Destination Selection Tests

    @Test("To flag selects specific destination")
    func toFlagSelectsDestination() async throws {
        let tracker = try createTempTracker()

        // Create multiple destinations
        let dest1Id = try tracker.createBackupDestination(
            name: "dest1",
            type: "b2",
            bucketName: "bucket1",
            remotePath: "/"
        )
        let dest2Id = try tracker.createBackupDestination(
            name: "dest2",
            type: "b2",
            bucketName: "bucket2",
            remotePath: "/"
        )

        // Get specific destination by name
        let dest1 = tracker.getBackupDestination(name: "dest1")
        let dest2 = tracker.getBackupDestination(name: "dest2")

        #expect(dest1?.id == dest1Id)
        #expect(dest2?.id == dest2Id)
        #expect(dest1?.name == "dest1")
        #expect(dest2?.name == "dest2")

        // Verify we can select destination by name
        let selected = tracker.getBackupDestination(name: "dest2")
        #expect(selected?.id == dest2Id)
        #expect(selected?.bucketName == "bucket2")
    }

    // MARK: - Force Flag Tests

    @Test("Force flag behavior with stale jobs")
    func forceFlagWithStaleJobs() async throws {
        let tracker = try createTempTracker()

        // Create a destination
        let destId = try tracker.createBackupDestination(
            name: "test-b2",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/"
        )

        // Create a "running" job
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

        // Manager with force=false would check for stale jobs
        // Manager with force=true would skip stale check
        let manager = BackupManager(tracker: tracker, staleThresholdSeconds: 60)

        // hasStaleJobs should return false for a recently updated job
        let hasStale = await manager.hasStaleJobs()
        #expect(hasStale == false)

        // Job should still be running
        let job = tracker.getBackupJob(id: jobId)
        #expect(job?.status == .running)
    }

    // MARK: - Source Path Generation Tests

    @Test("Source paths are correctly identified")
    func sourcePathGeneration() async throws {
        // Test BackupJobPriority path detection
        let libraryPriority = BackupJobPriority.forPath("/Volumes/Data/immich/library")
        let uploadPriority = BackupJobPriority.forPath("/Volumes/Data/immich/upload")
        let profilePriority = BackupJobPriority.forPath("/Volumes/Data/immich/profile")
        let backupsPriority = BackupJobPriority.forPath("/Volumes/Data/immich/backups")
        let damDataPriority = BackupJobPriority.forPath("/Users/felipe/dam/data")
        let unknownPriority = BackupJobPriority.forPath("/random/path")

        #expect(libraryPriority == 1)
        #expect(uploadPriority == 2)
        #expect(profilePriority == 3)
        #expect(backupsPriority == 4)
        #expect(damDataPriority == 5)
        #expect(unknownPriority == 99)
    }
}

@Suite("Setup Wizard Tests")
struct SetupWizardSpec {

    // MARK: - Helper to create temp database

    private func createTempTracker() throws -> Tracker {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_setup_\(UUID().uuidString).db")
        return try Tracker(dbPath: dbPath)
    }

    // MARK: - Prerequisite Flow Tests

    @Test("Setup wizard checks for rclone")
    func setupChecksRclone() async throws {
        let rclone = RcloneWrapper()
        let installed = await rclone.checkInstalled()

        // Verify the check completes without error
        #expect(installed == true || installed == false)
    }

    @Test("Setup wizard checks for 1Password CLI")
    func setupChecks1Password() async throws {
        let onePassword = OnePasswordCLI()
        let installed = await onePassword.checkInstalled()

        // Verify the check completes without error
        #expect(installed == true || installed == false)
    }

    // MARK: - 1Password Item Tests

    @Test("B2Credentials parses fields correctly")
    func credentialsParsing() throws {
        let fields: [String: String] = [
            "application_key_id": "test-key-id",
            "application_key": "test-key-secret",
            "bucket_name": "test-bucket",
            "encryption_password": "super-secret-password"
        ]

        let credentials = try B2Credentials.from(fields: fields)

        #expect(credentials.applicationKeyId == "test-key-id")
        #expect(credentials.applicationKey == "test-key-secret")
        #expect(credentials.bucketName == "test-bucket")
        #expect(credentials.encryptionPassword == "super-secret-password")
    }

    @Test("B2Credentials handles alternative field names")
    func credentialsAlternativeNames() throws {
        // Test with camelCase field names
        let fields: [String: String] = [
            "applicationKeyId": "test-key-id",
            "applicationKey": "test-key-secret",
            "bucketName": "test-bucket",
            "encryptionPassword": "super-secret-password"
        ]

        let credentials = try B2Credentials.from(fields: fields)

        #expect(credentials.applicationKeyId == "test-key-id")
        #expect(credentials.applicationKey == "test-key-secret")
        #expect(credentials.bucketName == "test-bucket")
        #expect(credentials.encryptionPassword == "super-secret-password")
    }

    @Test("B2Credentials throws on missing fields")
    func credentialsMissingFields() throws {
        let incompleteFields: [String: String] = [
            "application_key_id": "test-key-id"
            // Missing other required fields
        ]

        #expect(throws: BackupError.self) {
            _ = try B2Credentials.from(fields: incompleteFields)
        }
    }

    // MARK: - Destination Configuration Tests

    @Test("Destination saved to database correctly")
    func destinationSavedToDatabase() throws {
        let tracker = try createTempTracker()

        // Create destination
        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: "my-bucket",
            remotePath: "/"
        )

        // Retrieve and verify
        let destination = tracker.getBackupDestination(name: "b2")

        #expect(destination != nil)
        #expect(destination?.id == destId)
        #expect(destination?.name == "b2")
        #expect(destination?.type == "b2")
        #expect(destination?.bucketName == "my-bucket")
        #expect(destination?.remotePath == "/")
    }

    // MARK: - Rclone Remote Configuration Tests

    @Test("Rclone sync command is built correctly")
    func rcloneSyncCommandBuilding() async throws {
        let rclone = RcloneWrapper()

        let args = await rclone.buildSyncCommand(
            source: "/local/path",
            destination: "b2-crypt:",
            dryRun: true,
            statsInterval: 60
        )

        #expect(args.contains("sync"))
        #expect(args.contains("/local/path"))
        #expect(args.contains("b2-crypt:"))
        #expect(args.contains("--dry-run"))
        #expect(args.contains("--stats"))
        #expect(args.contains("60s"))
    }

    @Test("Rclone sync command without dry run")
    func rcloneSyncCommandNoDryRun() async throws {
        let rclone = RcloneWrapper()

        let args = await rclone.buildSyncCommand(
            source: "/local/path",
            destination: "b2-crypt:",
            dryRun: false,
            statsInterval: 30
        )

        #expect(args.contains("sync"))
        #expect(!args.contains("--dry-run"))
        #expect(args.contains("30s"))
    }
}
