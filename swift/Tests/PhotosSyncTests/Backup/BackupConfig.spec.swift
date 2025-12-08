import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("Backup Config Tests")
struct BackupConfigSpec {

    /// Create a temporary .env file for testing
    func createTestEnv(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("dam_config_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let envPath = testDir.appendingPathComponent(".env")
        try content.write(to: envPath, atomically: true, encoding: .utf8)

        return testDir
    }

    func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Loads BACKUP_IMMICH_PATH from .env")
    func loadBackupImmichPath() throws {
        let envContent = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        BACKUP_IMMICH_PATH=/mnt/immich/data
        """

        let testDir = try createTestEnv(content: envContent)
        defer { cleanup(testDir) }

        let config = Config.load(fromDirectory: testDir)
        #expect(config != nil)
        #expect(config?.backupImmichPath == "/mnt/immich/data")
    }

    @Test("Loads BACKUP_STATS_INTERVAL with default")
    func loadBackupStatsInterval() throws {
        // With custom interval
        let envContent1 = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        BACKUP_STATS_INTERVAL=30
        """

        let testDir1 = try createTestEnv(content: envContent1)
        defer { cleanup(testDir1) }

        let config1 = Config.load(fromDirectory: testDir1)
        #expect(config1?.backupStatsInterval == 30)

        // Without custom interval (should use default 60)
        let envContent2 = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        """

        let testDir2 = try createTestEnv(content: envContent2)
        defer { cleanup(testDir2) }

        let config2 = Config.load(fromDirectory: testDir2)
        #expect(config2?.backupStatsInterval == 60)
    }

    @Test("Loads BACKUP_MAX_RETRIES with default")
    func loadBackupMaxRetries() throws {
        // With custom max retries
        let envContent1 = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        BACKUP_MAX_RETRIES=5
        """

        let testDir1 = try createTestEnv(content: envContent1)
        defer { cleanup(testDir1) }

        let config1 = Config.load(fromDirectory: testDir1)
        #expect(config1?.backupMaxRetries == 5)

        // Without custom max retries (should use default 3)
        let envContent2 = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        """

        let testDir2 = try createTestEnv(content: envContent2)
        defer { cleanup(testDir2) }

        let config2 = Config.load(fromDirectory: testDir2)
        #expect(config2?.backupMaxRetries == 3)
    }

    @Test("Missing backup config returns nil gracefully")
    func missingBackupConfig() throws {
        let envContent = """
        IMMICH_URL=http://localhost:2283
        IMMICH_API_KEY=test-key
        """

        let testDir = try createTestEnv(content: envContent)
        defer { cleanup(testDir) }

        let config = Config.load(fromDirectory: testDir)
        #expect(config != nil)
        #expect(config?.backupImmichPath == nil)
    }
}
