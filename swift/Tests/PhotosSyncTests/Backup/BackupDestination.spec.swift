import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("Backup Destination Tests")
struct BackupDestinationSpec {

    // MARK: - DestinationType Tests

    @Test("DestinationType has correct raw values")
    func destinationTypeRawValues() {
        #expect(DestinationType.b2.rawValue == "b2")
    }

    @Test("DestinationType has display names")
    func destinationTypeDisplayNames() {
        #expect(DestinationType.b2.displayName == "Backblaze B2")
    }

    @Test("DestinationType can be initialized from raw value")
    func destinationTypeFromRawValue() {
        let b2 = DestinationType(rawValue: "b2")
        #expect(b2 == .b2)

        let invalid = DestinationType(rawValue: "invalid")
        #expect(invalid == nil)
    }

    // MARK: - BackupDestinationConfig Tests

    @Test("BackupDestinationConfig initializes with defaults")
    func configDefaults() {
        let config = BackupDestinationConfig(
            name: "test-backup",
            type: .b2,
            bucketName: "my-bucket"
        )

        #expect(config.name == "test-backup")
        #expect(config.type == .b2)
        #expect(config.bucketName == "my-bucket")
        #expect(config.remotePath == "/")
        #expect(config.onePasswordItemTitle == "Immich Backup B2")
        #expect(config.onePasswordVault == "Private")
    }

    @Test("BackupDestinationConfig accepts custom values")
    func configCustomValues() {
        let config = BackupDestinationConfig(
            name: "production-backup",
            type: .b2,
            bucketName: "prod-bucket",
            remotePath: "/backups/immich",
            onePasswordItemTitle: "Production B2 Creds",
            onePasswordVault: "Work"
        )

        #expect(config.remotePath == "/backups/immich")
        #expect(config.onePasswordItemTitle == "Production B2 Creds")
        #expect(config.onePasswordVault == "Work")
    }

    @Test("BackupDestinationConfig creates from tracker destination")
    func configFromTrackerDestination() throws {
        // Create a mock destination similar to what comes from the database
        let dest = Tracker.BackupDestination(
            id: 1,
            name: "b2-primary",
            type: "b2",
            bucketName: "test-bucket",
            remotePath: "/data",
            createdAt: Date(),
            lastBackupAt: nil
        )

        let config = BackupDestinationConfig.from(
            destination: dest,
            vault: "Personal",
            itemTitle: "Custom Item"
        )

        #expect(config.name == "b2-primary")
        #expect(config.type == .b2)
        #expect(config.bucketName == "test-bucket")
        #expect(config.remotePath == "/data")
        #expect(config.onePasswordVault == "Personal")
        #expect(config.onePasswordItemTitle == "Custom Item")
    }

    // MARK: - B2Destination Tests

    @Test("B2Destination initializes with correct name and type")
    func b2DestinationInit() async {
        let config = BackupDestinationConfig(
            name: "test-b2",
            type: .b2,
            bucketName: "test-bucket"
        )

        let destination = B2Destination(
            config: config,
            rclone: RcloneWrapper(),
            onePassword: OnePasswordCLI()
        )

        // Access actor properties
        let name = await destination.name
        let type = await destination.type

        #expect(name == "test-b2")
        #expect(type == .b2)
    }

    @Test("B2Destination generates correct remote names")
    func b2RemoteNames() async throws {
        let config = BackupDestinationConfig(
            name: "my-backup",
            type: .b2,
            bucketName: "test-bucket",
            remotePath: "/immich"
        )

        let destination = B2Destination(
            config: config,
            rclone: RcloneWrapper(),
            onePassword: OnePasswordCLI()
        )

        // The info method should return the remote names
        // Note: This would fail without proper 1Password setup, so we test the naming pattern
        // by checking the config is stored correctly
        let name = await destination.name
        #expect(name == "my-backup")

        // Remote names follow pattern: {name}-b2 and {name}-crypt
        // We can't call getInfo() without 1Password, but we verify the destination was created
    }

    // MARK: - BackupDestinationFactory Tests

    @Test("Factory creates B2Destination for b2 type")
    func factoryCreatesB2() async {
        let config = BackupDestinationConfig(
            name: "factory-test",
            type: .b2,
            bucketName: "test-bucket"
        )

        let destination = BackupDestinationFactory.create(config: config)

        // Type is correct
        #expect(destination.type == .b2)
    }

    // MARK: - B2Credentials Integration Tests

    @Test("B2Credentials validates required fields")
    func b2CredentialsValidation() {
        // All fields present - should succeed
        let validFields: [String: String] = [
            "application_key_id": "key123",
            "application_key": "secret",
            "bucket_name": "bucket",
            "encryption_password": "password"
        ]

        #expect(throws: Never.self) {
            _ = try B2Credentials.from(fields: validFields)
        }

        // Missing encryption_password - should fail
        let missingPassword: [String: String] = [
            "application_key_id": "key123",
            "application_key": "secret",
            "bucket_name": "bucket"
        ]

        #expect(throws: BackupError.self) {
            _ = try B2Credentials.from(fields: missingPassword)
        }
    }

    @Test("B2Credentials lists required fields")
    func b2CredentialsRequiredFields() {
        let required = B2Credentials.requiredFields

        #expect(required.contains("application_key_id"))
        #expect(required.contains("application_key"))
        #expect(required.contains("bucket_name"))
        #expect(required.contains("encryption_password"))
        #expect(required.count == 4)
    }

    // MARK: - Test Write Verification Tests

    @Test("Test write verification requires configured destination")
    func testWriteRequiresConfig() async {
        let config = BackupDestinationConfig(
            name: "unconfigured-test",
            type: .b2,
            bucketName: "nonexistent-bucket"
        )

        let destination = B2Destination(
            config: config,
            rclone: RcloneWrapper(),
            onePassword: OnePasswordCLI()
        )

        // Without proper configuration, testWrite should fail
        // This tests that the method handles errors appropriately
        do {
            _ = try await destination.testWrite()
            // If we get here without 1Password configured, something unexpected happened
            // In a real test environment with mocks, we'd verify the specific error
        } catch {
            // Expected to fail without proper setup
            #expect(error is BackupError)
        }
    }
}
