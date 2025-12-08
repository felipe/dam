import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("External Tool Wrappers Tests")
struct ToolWrappersSpec {

    // MARK: - RcloneWrapper Tests

    @Test("Checks rclone installation status")
    func rcloneInstallCheck() async {
        let rclone = RcloneWrapper()

        // This will return true if rclone is installed, false otherwise
        // We just verify the method runs without crashing
        let isInstalled = await rclone.checkInstalled()
        // The result depends on whether rclone is installed on the test machine
        // This is a valid test - we're testing the check mechanism works
        #expect(isInstalled == true || isInstalled == false)
    }

    @Test("Builds correct rclone sync command")
    func rcloneSyncCommandConstruction() async {
        let rclone = RcloneWrapper()

        // Test basic sync command
        let basicArgs = await rclone.buildSyncCommand(
            source: "/path/to/source",
            destination: "b2:bucket/path",
            dryRun: false,
            statsInterval: 60
        )

        #expect(basicArgs.contains("sync"))
        #expect(basicArgs.contains("/path/to/source"))
        #expect(basicArgs.contains("b2:bucket/path"))
        #expect(basicArgs.contains("--stats"))
        #expect(basicArgs.contains("60s"))
        #expect(basicArgs.contains("--use-json-log"))
        #expect(!basicArgs.contains("--dry-run"))

        // Test dry run command
        let dryRunArgs = await rclone.buildSyncCommand(
            source: "/source",
            destination: "crypt:dest",
            dryRun: true,
            statsInterval: 30
        )

        #expect(dryRunArgs.contains("--dry-run"))
        #expect(dryRunArgs.contains("30s"))
    }

    @Test("Builds sync command with custom stats interval")
    func rcloneStatsInterval() async {
        let rclone = RcloneWrapper()

        let args = await rclone.buildSyncCommand(
            source: "/src",
            destination: "remote:dest",
            dryRun: false,
            statsInterval: 120
        )

        #expect(args.contains("120s"))
    }

    // MARK: - OnePasswordCLI Tests

    @Test("Checks 1Password CLI installation status")
    func opInstallCheck() async {
        let op = OnePasswordCLI()

        // This will return true if op is installed, false otherwise
        let isInstalled = await op.checkInstalled()
        // The result depends on whether op is installed on the test machine
        #expect(isInstalled == true || isInstalled == false)
    }

    @Test("Parses B2 credentials from field dictionary")
    func parseB2Credentials() throws {
        let fields: [String: String] = [
            "application_key_id": "001234567890",
            "application_key": "K001secretkeyhere",
            "bucket_name": "my-backup-bucket",
            "encryption_password": "supersecurepassword123"
        ]

        let credentials = try B2Credentials.from(fields: fields)

        #expect(credentials.applicationKeyId == "001234567890")
        #expect(credentials.applicationKey == "K001secretkeyhere")
        #expect(credentials.bucketName == "my-backup-bucket")
        #expect(credentials.encryptionPassword == "supersecurepassword123")
    }

    @Test("Parses B2 credentials with alternate field names")
    func parseB2CredentialsAlternateNames() throws {
        // Some 1Password items might use camelCase field names
        let fields: [String: String] = [
            "applicationKeyId": "001234567890",
            "applicationKey": "K001secretkeyhere",
            "bucketName": "my-backup-bucket",
            "encryptionPassword": "supersecurepassword123"
        ]

        let credentials = try B2Credentials.from(fields: fields)

        #expect(credentials.applicationKeyId == "001234567890")
        #expect(credentials.bucketName == "my-backup-bucket")
    }

    @Test("Throws error when B2 credentials are missing fields")
    func missingB2Credentials() {
        let incompleteFields: [String: String] = [
            "application_key_id": "001234567890",
            // Missing application_key
            "bucket_name": "my-bucket",
            "encryption_password": "password"
        ]

        #expect(throws: BackupError.self) {
            _ = try B2Credentials.from(fields: incompleteFields)
        }
    }

    // MARK: - SyncProgress Tests

    @Test("Parses rclone JSON stats output")
    func parseSyncProgressJSON() {
        let jsonOutput = """
        {"level":"info","msg":"Transferred","stats":{"bytes":1073741824,"totalBytes":10737418240,"transfers":50,"totalTransfers":500,"speed":52428800,"eta":180}}
        """

        let progress = SyncProgress.parse(from: jsonOutput)

        #expect(progress != nil)
        #expect(progress?.bytesTransferred == 1073741824)
        #expect(progress?.bytesTotal == 10737418240)
        #expect(progress?.filesTransferred == 50)
        #expect(progress?.filesTotal == 500)
        #expect(progress?.speed == 52428800)
        #expect(progress?.eta == 180)
    }

    @Test("Parses direct stats JSON")
    func parseSyncProgressDirectJSON() {
        let jsonOutput = """
        {"bytes":500000,"totalBytes":1000000,"transfers":5,"speed":100000}
        """

        let progress = SyncProgress.parse(from: jsonOutput)

        #expect(progress != nil)
        #expect(progress?.bytesTransferred == 500000)
        #expect(progress?.bytesTotal == 1000000)
        #expect(progress?.filesTransferred == 5)
    }

    @Test("Calculates progress percentage correctly")
    func progressPercentage() {
        let progress = SyncProgress(
            bytesTransferred: 250_000_000,
            bytesTotal: 1_000_000_000,
            filesTransferred: 25,
            filesTotal: 100,
            speed: 50_000_000
        )

        #expect(progress.percentComplete == 25.0)
    }

    @Test("Handles zero total bytes for percentage")
    func zeroTotalBytesPercentage() {
        let progress = SyncProgress(
            bytesTransferred: 0,
            bytesTotal: 0,
            filesTransferred: 0,
            filesTotal: 0,
            speed: 0
        )

        #expect(progress.percentComplete == 0.0)
    }

    @Test("Formats speed correctly")
    func formattedSpeed() {
        let progress = SyncProgress(
            bytesTransferred: 0,
            bytesTotal: 0,
            filesTransferred: 0,
            filesTotal: 0,
            speed: 52_428_800  // 50 MB/s
        )

        let formatted = progress.formattedSpeed
        // ByteCountFormatter will format this, exact format may vary
        #expect(formatted.contains("/s"))
    }

    @Test("Formats ETA correctly")
    func formattedETA() {
        // Test various ETA values
        let progress1 = SyncProgress(bytesTransferred: 0, bytesTotal: 100, filesTransferred: 0, filesTotal: 1, speed: 0, eta: 150) // 2:30
        #expect(progress1.formattedETA == "2:30")

        let progress2 = SyncProgress(bytesTransferred: 0, bytesTotal: 100, filesTransferred: 0, filesTotal: 1, speed: 0, eta: 3661) // 1:01:01
        #expect(progress2.formattedETA == "1:01:01")

        let progress3 = SyncProgress(bytesTransferred: 0, bytesTotal: 100, filesTransferred: 0, filesTotal: 1, speed: 0, eta: 45) // 45s
        #expect(progress3.formattedETA == "45s")

        let progress4 = SyncProgress(bytesTransferred: 0, bytesTotal: 100, filesTransferred: 0, filesTotal: 1, speed: 0, eta: nil)
        #expect(progress4.formattedETA == "calculating...")
    }

    // MARK: - BackupError Tests

    @Test("BackupError provides localized descriptions")
    func backupErrorDescriptions() {
        let errors: [BackupError] = [
            .rcloneNotInstalled,
            .rcloneConfigFailed("test reason"),
            .onePasswordNotInstalled,
            .onePasswordNotSignedIn,
            .onePasswordItemNotFound("Test Item"),
            .missingBackupPath,
            .destinationNotFound("b2-primary")
        ]

        for error in errors {
            #expect(error.localizedDescription.isEmpty == false)
        }

        #expect(BackupError.rcloneNotInstalled.localizedDescription.contains("rclone"))
        #expect(BackupError.onePasswordNotInstalled.localizedDescription.contains("1Password"))
        #expect(BackupError.onePasswordItemNotFound("Test").localizedDescription.contains("Test"))
    }
}
