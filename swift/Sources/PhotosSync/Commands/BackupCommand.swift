import PhotosSyncLib
import ArgumentParser
import Foundation

struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Backup Immich data to encrypted cloud storage"
    )

    // MARK: - Command Options

    @Flag(name: .long, help: "Check prerequisites (rclone, 1Password CLI)")
    var check: Bool = false

    @Flag(name: .long, help: "Run setup wizard for B2 destination")
    var setup: Bool = false

    @Option(name: .long, help: "Destination name (default: b2)")
    var to: String?

    @Flag(name: .long, help: "Show backup status")
    var status: Bool = false

    @Flag(name: .long, help: "Force backup ignoring stale jobs")
    var force: Bool = false

    @Flag(name: .long, help: "Show what would be synced without transferring")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Clear all job state for destination")
    var reset: Bool = false

    // MARK: - Run

    func run() async throws {
        // Handle --check
        if check {
            try await runPrerequisiteCheck()
            return
        }

        // Handle --setup
        if setup {
            try await runSetupWizard()
            return
        }

        // Handle --status
        if status {
            try await showStatus()
            return
        }

        // Handle --reset
        if reset {
            try await resetJobs()
            return
        }

        // Default: run backup
        try await runBackup()
    }

    // MARK: - Prerequisite Check (--check)

    private func runPrerequisiteCheck() async throws {
        print("Checking backup prerequisites...")
        print()

        var allPassed = true

        // Check rclone
        let rclone = RcloneWrapper()
        let rcloneInstalled = await rclone.checkInstalled()
        if rcloneInstalled {
            print("[OK] rclone is installed")
            if let version = try? await rclone.getVersion() {
                print("     \(version)")
            }
        } else {
            print("[FAIL] rclone is not installed")
            print("       Install with: brew install rclone")
            allPassed = false
        }

        // Check 1Password CLI
        let onePassword = OnePasswordCLI()
        let opInstalled = await onePassword.checkInstalled()
        if opInstalled {
            print("[OK] 1Password CLI is installed")
        } else {
            print("[FAIL] 1Password CLI is not installed")
            print("       Install with: brew install 1password-cli")
            allPassed = false
        }

        // Check 1Password sign-in
        if opInstalled {
            let signedIn = await onePassword.checkSignedIn()
            if signedIn {
                print("[OK] 1Password CLI is signed in")
            } else {
                print("[FAIL] 1Password CLI is not signed in")
                print("       Sign in with: op signin")
                allPassed = false
            }
        }

        // Check BACKUP_IMMICH_PATH
        if let config = Config.load() {
            if let path = config.backupImmichPath, !path.isEmpty {
                print("[OK] BACKUP_IMMICH_PATH is configured")
                print("     \(path)")
                // Check if path exists
                if FileManager.default.fileExists(atPath: path) {
                    print("[OK] Backup source path exists")
                } else {
                    print("[WARN] Backup source path does not exist")
                }
            } else {
                print("[WARN] BACKUP_IMMICH_PATH not configured in .env")
            }
        } else {
            print("[FAIL] Could not load config")
            allPassed = false
        }

        print()
        if allPassed {
            print("All prerequisites met. Ready to run backup.")
        } else {
            print("Some prerequisites are missing. Please install them first.")
            throw ExitCode.failure
        }
    }

    // MARK: - Status (--status)

    private func showStatus() async throws {
        guard let config = Config.load() else {
            print("ERROR: Could not load config")
            throw ExitCode.failure
        }

        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let manager = BackupManager(
            tracker: tracker,
            staleThresholdSeconds: config.backupStatsInterval,
            maxRetries: config.backupMaxRetries
        )

        let destinations = tracker.getBackupDestinations()

        if destinations.isEmpty {
            print("No backup destinations configured.")
            print("Run 'photos-sync backup --setup' to configure a destination.")
            return
        }

        print()
        print(String(repeating: "=", count: 60))
        print("BACKUP STATUS")
        print(String(repeating: "=", count: 60))

        for destination in destinations {
            // Skip if --to specified and doesn't match
            if let toName = to, destination.name != toName {
                continue
            }

            let status = await manager.getStatus(destinationId: destination.id)
            print()
            print("Destination: \(destination.name) (\(destination.type))")
            print("  Bucket: \(destination.bucketName)")
            print("  Last backup: \(status.formattedLastBackupAt)")
            print()
            print("  Job Status:")
            print("    Total jobs:      \(status.totalJobs)")
            print("    Completed:       \(status.completedJobs)")
            print("    Running:         \(status.runningJobs)")
            print("    Pending:         \(status.pendingJobs)")
            print("    Failed:          \(status.failedJobs)")
            print("    Interrupted:     \(status.interruptedJobs)")
            print()
            print("  Transfer Progress:")
            print("    Bytes transferred: \(status.formattedTotalBytesTransferred)")
            print("    Files transferred: \(formatNumber(Int(status.totalFilesTransferred)))")
            print("    Completion:        \(String(format: "%.1f", status.completionPercentage))%")

            // Show current job details if running
            if let currentJob = status.currentJob {
                print()
                print("  Currently Running:")
                print("    Source: \(currentJob.sourceDirectoryName)")
                print("    Progress: \(currentJob.formattedBytesTransferred) / \(currentJob.formattedBytesTotal)")
                print("    Speed: \(currentJob.formattedSpeed)")
            }

            // Show failed jobs with error messages
            let jobs = tracker.getBackupJobs(destinationId: destination.id)
            let failedJobs = jobs.filter { $0.status == .failed }
            if !failedJobs.isEmpty {
                print()
                print("  Failed Jobs:")
                for job in failedJobs {
                    print("    - \(job.sourceDirectoryName): \(job.errorMessage ?? "Unknown error")")
                    print("      Retry count: \(job.retryCount)/\(config.backupMaxRetries)")
                }
            }

            // Show stale jobs warning
            let staleJobs = await manager.getStaleJobs()
            if !staleJobs.isEmpty {
                print()
                print("  [WARN] Stale Jobs Detected:")
                for job in staleJobs {
                    print("    - \(job.sourceDirectoryName): Last update \(formatTimeSince(job.lastUpdate))")
                }
                print("  Run with --force to proceed anyway, or --reset to clear state")
            }
        }

        print()
        print(String(repeating: "=", count: 60))
    }

    // MARK: - Reset (--reset)

    private func resetJobs() async throws {
        guard let config = Config.load() else {
            print("ERROR: Could not load config")
            throw ExitCode.failure
        }

        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let manager = BackupManager(tracker: tracker)

        let destinationName = to ?? "b2"
        guard let destination = tracker.getBackupDestination(name: destinationName) else {
            print("ERROR: Destination '\(destinationName)' not found")
            throw ExitCode.failure
        }

        // Confirm reset
        print("This will delete all job state for destination '\(destinationName)'.")
        print("Are you sure? [y/N] ", terminator: "")
        fflush(stdout)

        guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
            print("Cancelled.")
            return
        }

        try await manager.resetJobs(destinationId: destination.id)
        print("All job state reset for destination '\(destinationName)'.")
    }

    // MARK: - Main Backup Execution

    private func runBackup() async throws {
        print("photos-sync backup starting...")

        guard let config = Config.load() else {
            print("ERROR: Could not load config")
            throw ExitCode.failure
        }

        // Verify BACKUP_IMMICH_PATH is set
        guard let immichPath = config.backupImmichPath, !immichPath.isEmpty else {
            print("ERROR: BACKUP_IMMICH_PATH not configured in .env")
            print("Set the path to your Immich data directory.")
            throw ExitCode.failure
        }

        // Verify path exists
        guard FileManager.default.fileExists(atPath: immichPath) else {
            print("ERROR: Backup source path does not exist: \(immichPath)")
            throw ExitCode.failure
        }

        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let manager = BackupManager(
            tracker: tracker,
            staleThresholdSeconds: config.backupStatsInterval,
            maxRetries: config.backupMaxRetries,
            logPath: config.dataDir.appendingPathComponent("backup.log")
        )

        // Get or validate destination
        let destinationName = to ?? "b2"
        guard let dbDestination = tracker.getBackupDestination(name: destinationName) else {
            print("ERROR: Destination '\(destinationName)' not found")
            print("Run 'photos-sync backup --setup' to configure a destination.")
            throw ExitCode.failure
        }

        // Check for stale jobs unless --force
        if !force {
            let staleJobs = await manager.getStaleJobs()
            if !staleJobs.isEmpty {
                print("WARNING: Found \(staleJobs.count) stale job(s):")
                for job in staleJobs {
                    print("  - \(job.sourceDirectoryName): Last update \(formatTimeSince(job.lastUpdate))")
                }
                print()
                print("These jobs may have been interrupted. Options:")
                print("  - Run with --force to proceed (will mark stale jobs as interrupted and resume)")
                print("  - Run with --reset to clear all job state and start fresh")
                throw ExitCode.failure
            }
        }

        // Create B2 destination
        let destConfig = BackupDestinationConfig.from(destination: dbDestination)
        let destination = BackupDestinationFactory.create(config: destConfig)

        // Check if we have jobs, create them if not
        let existingJobs = tracker.getBackupJobs(destinationId: dbDestination.id)
        if existingJobs.isEmpty {
            print("Creating backup jobs for source paths...")

            // Define source directories to back up
            let sourcePaths = getSourcePaths(immichPath: immichPath, dataDir: config.dataDir)

            let jobs = try await manager.createJobsForSource(
                paths: sourcePaths,
                destinationId: dbDestination.id
            )

            print("Created \(jobs.count) backup job(s)")
        }

        // Run the backup
        print()
        print("Starting backup to \(destinationName)...")
        if dryRun {
            print("[DRY RUN] No files will actually be transferred")
        }
        print()

        do {
            try await manager.runBackup(
                destination: destination,
                destinationId: dbDestination.id,
                dryRun: dryRun,
                force: force
            )

            print()
            print("Backup completed successfully!")

        } catch {
            print()
            print("ERROR: Backup failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Setup Wizard (--setup)

    private func runSetupWizard() async throws {
        print("Backup Setup Wizard")
        print(String(repeating: "=", count: 40))
        print()

        // Currently only B2 is supported
        let destinationType = DestinationType.b2
        print("Setting up \(destinationType.displayName) backup destination...")
        print()

        // Step 1: Check prerequisites
        print("Step 1: Checking prerequisites...")
        try await checkPrerequisites()
        print()

        // Step 2: Check for existing 1Password item
        print("Step 2: Checking 1Password for credentials...")
        let (credentials, _) = try await setupOnePasswordItem()
        print()

        // Step 3: Validate credentials have required fields
        print("Step 3: Validating credentials...")
        try validateCredentials(credentials)
        print("[OK] All required fields present")
        print()

        // Step 4: Configure rclone B2 remote
        print("Step 4: Configuring rclone B2 remote...")
        try await configureRcloneB2(credentials: credentials)
        print()

        // Step 5: Configure rclone crypt overlay
        print("Step 5: Configuring rclone encryption...")
        try await configureRcloneCrypt(credentials: credentials)
        print()

        // Step 6: Test write verification
        print("Step 6: Testing encryption with test write...")
        try await verifyTestWrite()
        print()

        // Step 7: Save destination to database
        print("Step 7: Saving destination configuration...")
        try await saveDestination(credentials: credentials)
        print()

        print(String(repeating: "=", count: 40))
        print("Setup complete!")
        print()
        print("You can now run: photos-sync backup")
        print()
    }

    private func checkPrerequisites() async throws {
        let rclone = RcloneWrapper()
        guard await rclone.checkInstalled() else {
            print("[FAIL] rclone is not installed")
            print("       Install with: brew install rclone")
            throw ExitCode.failure
        }
        print("[OK] rclone is installed")

        let onePassword = OnePasswordCLI()
        guard await onePassword.checkInstalled() else {
            print("[FAIL] 1Password CLI is not installed")
            print("       Install with: brew install 1password-cli")
            throw ExitCode.failure
        }
        print("[OK] 1Password CLI is installed")

        guard await onePassword.checkSignedIn() else {
            print("[FAIL] 1Password CLI is not signed in")
            print("       Sign in with: op signin")
            throw ExitCode.failure
        }
        print("[OK] 1Password CLI is signed in")
    }

    private func setupOnePasswordItem() async throws -> (B2Credentials, Bool) {
        let onePassword = OnePasswordCLI()
        let vault = "Private"
        let itemTitle = "Immich Backup B2"

        // Check if item exists
        let itemExists = await onePassword.itemExists(vault: vault, title: itemTitle)

        if itemExists {
            print("[OK] Found existing 1Password item: \(itemTitle)")

            // Load credentials
            let fields = try await onePassword.getItem(vault: vault, title: itemTitle)
            let credentials = try B2Credentials.from(fields: fields)
            return (credentials, false)
        }

        // Item doesn't exist - offer to create it
        print("[INFO] 1Password item '\(itemTitle)' not found")
        print()
        print("Would you like to create it now? [Y/n] ", terminator: "")
        fflush(stdout)

        let response = readLine()?.lowercased() ?? "y"
        guard response.isEmpty || response == "y" || response == "yes" else {
            print("Cancelled. Please create the 1Password item manually with these fields:")
            print("  - application_key_id: Your B2 Application Key ID")
            print("  - application_key: Your B2 Application Key")
            print("  - bucket_name: Your B2 bucket name")
            print("  - encryption_password: (will be generated)")
            throw ExitCode.failure
        }

        // Generate encryption password
        print()
        print("Generating secure encryption password...")
        let encryptionPassword = try await onePassword.generatePassword(length: 32)
        print("[OK] Encryption password generated (32 characters)")

        // Create the 1Password item with placeholder values
        print()
        print("Creating 1Password item...")
        try await onePassword.createItem(
            vault: vault,
            title: itemTitle,
            category: "Secure Note",
            fields: [
                "application_key_id": "REPLACE_WITH_YOUR_B2_KEY_ID",
                "application_key": "REPLACE_WITH_YOUR_B2_KEY",
                "bucket_name": "REPLACE_WITH_YOUR_BUCKET_NAME",
                "encryption_password": encryptionPassword
            ]
        )
        print("[OK] Created 1Password item: \(itemTitle)")

        // Prompt user to fill in B2 credentials
        print()
        print(String(repeating: "-", count: 50))
        print("IMPORTANT: Please update the 1Password item with your B2 credentials:")
        print("  1. Open 1Password and find '\(itemTitle)'")
        print("  2. Replace 'REPLACE_WITH_YOUR_B2_KEY_ID' with your B2 Application Key ID")
        print("  3. Replace 'REPLACE_WITH_YOUR_B2_KEY' with your B2 Application Key")
        print("  4. Replace 'REPLACE_WITH_YOUR_BUCKET_NAME' with your bucket name")
        print("  5. Keep the encryption_password as generated")
        print(String(repeating: "-", count: 50))
        print()
        print("Press Enter when you have updated the credentials...", terminator: "")
        fflush(stdout)
        _ = readLine()

        // Re-read and validate credentials
        print()
        print("Verifying updated credentials...")
        let fields = try await onePassword.getItem(vault: vault, title: itemTitle)
        let credentials = try B2Credentials.from(fields: fields)

        // Check if still has placeholder values
        if credentials.applicationKeyId.contains("REPLACE") ||
           credentials.applicationKey.contains("REPLACE") ||
           credentials.bucketName.contains("REPLACE") {
            print("[FAIL] Credentials still contain placeholder values")
            print("Please update the 1Password item and run setup again.")
            throw ExitCode.failure
        }

        print("[OK] Credentials updated successfully")
        return (credentials, true)
    }

    private func validateCredentials(_ credentials: B2Credentials) throws {
        // Check that all required fields have non-empty values
        guard !credentials.applicationKeyId.isEmpty else {
            throw BackupError.credentialsNotFound("application_key_id is empty")
        }
        guard !credentials.applicationKey.isEmpty else {
            throw BackupError.credentialsNotFound("application_key is empty")
        }
        guard !credentials.bucketName.isEmpty else {
            throw BackupError.credentialsNotFound("bucket_name is empty")
        }
        guard !credentials.encryptionPassword.isEmpty else {
            throw BackupError.credentialsNotFound("encryption_password is empty")
        }
    }

    private func configureRcloneB2(credentials: B2Credentials) async throws {
        let rclone = RcloneWrapper()
        let remoteName = "b2-b2"

        // Delete existing remote if present
        let existingRemotes = try await rclone.listRemotes()
        if existingRemotes.contains(remoteName) {
            print("  Removing existing remote '\(remoteName)'...")
            try await rclone.deleteRemote(name: remoteName)
        }

        // Create B2 remote
        print("  Creating B2 remote '\(remoteName)'...")
        try await rclone.configureRemote(
            name: remoteName,
            type: "b2",
            config: [
                "account": credentials.applicationKeyId,
                "key": credentials.applicationKey
            ]
        )

        // Test connection
        print("  Testing B2 connection...")
        let connectionOK = try await rclone.testConnection(remote: remoteName)
        guard connectionOK else {
            print("[FAIL] Could not connect to B2")
            print("       Please check your credentials in 1Password")
            throw BackupError.rcloneTestFailed("B2 connection failed")
        }
        print("[OK] B2 remote configured and connected")
    }

    private func configureRcloneCrypt(credentials: B2Credentials) async throws {
        let rclone = RcloneWrapper()
        let b2RemoteName = "b2-b2"
        let cryptRemoteName = "b2-crypt"

        // Delete existing crypt remote if present
        let existingRemotes = try await rclone.listRemotes()
        if existingRemotes.contains(cryptRemoteName) {
            print("  Removing existing remote '\(cryptRemoteName)'...")
            try await rclone.deleteRemote(name: cryptRemoteName)
        }

        // Create crypt remote wrapping B2
        let cryptTarget = "\(b2RemoteName):\(credentials.bucketName)"
        print("  Creating crypt remote '\(cryptRemoteName)'...")
        print("  Target: \(cryptTarget)")

        try await rclone.configureRemote(
            name: cryptRemoteName,
            type: "crypt",
            config: [
                "remote": cryptTarget,
                "password": credentials.encryptionPassword,
                "filename_encryption": "standard",
                "directory_name_encryption": "true"
            ]
        )
        print("[OK] Crypt remote configured with encryption")
    }

    private func verifyTestWrite() async throws {
        let rclone = RcloneWrapper()
        let cryptRemoteName = "b2-crypt"

        print("  Writing test file to encrypted remote...")
        let testContent = "Backup test - \(Date().ISO8601Format())"
        let testOK = try await rclone.testWrite(remote: cryptRemoteName, testContent: testContent)

        guard testOK else {
            print("[FAIL] Test write failed")
            print("       Encryption may not be configured correctly")
            throw BackupError.testWriteFailed("Could not verify encryption")
        }
        print("[OK] Test write successful - encryption working")
    }

    private func saveDestination(credentials: B2Credentials) async throws {
        guard let config = Config.load() else {
            print("[FAIL] Could not load config")
            throw ExitCode.failure
        }

        let tracker = try Tracker(dbPath: config.trackerDBPath)

        // Check if destination already exists
        if let existing = tracker.getBackupDestination(name: "b2") {
            print("  Destination 'b2' already exists (ID: \(existing.id))")
            print("[OK] Using existing destination")
            return
        }

        // Create new destination
        let destId = try tracker.createBackupDestination(
            name: "b2",
            type: "b2",
            bucketName: credentials.bucketName,
            remotePath: "/"
        )
        print("[OK] Saved destination 'b2' (ID: \(destId))")
    }

    // MARK: - Helpers

    private func getSourcePaths(immichPath: String, dataDir: URL) -> [String] {
        // Standard Immich directories to back up (in priority order)
        var paths: [String] = []

        let libraryPath = "\(immichPath)/library"
        if FileManager.default.fileExists(atPath: libraryPath) {
            paths.append(libraryPath)
        }

        let uploadPath = "\(immichPath)/upload"
        if FileManager.default.fileExists(atPath: uploadPath) {
            paths.append(uploadPath)
        }

        let profilePath = "\(immichPath)/profile"
        if FileManager.default.fileExists(atPath: profilePath) {
            paths.append(profilePath)
        }

        let backupsPath = "\(immichPath)/backups"
        if FileManager.default.fileExists(atPath: backupsPath) {
            paths.append(backupsPath)
        }

        // Also back up local dam/data directory
        if FileManager.default.fileExists(atPath: dataDir.path) {
            paths.append(dataDir.path)
        }

        return paths
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatTimeSince(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
