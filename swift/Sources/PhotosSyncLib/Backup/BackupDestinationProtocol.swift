import Foundation

/// Types of backup destinations supported
public enum DestinationType: String, Sendable, CaseIterable {
    case b2 = "b2"
    // Future destinations:
    // case glacier = "glacier"
    // case s3 = "s3"

    public var displayName: String {
        switch self {
        case .b2:
            return "Backblaze B2"
        }
    }
}

/// Protocol for backup destination implementations
/// Allows future extension to Glacier, S3, etc.
public protocol BackupDestinationProtocol: Sendable {
    /// Unique name for this destination
    var name: String { get }

    /// Type of the destination
    var type: DestinationType { get }

    /// Configure the destination (set up rclone remotes, etc.)
    func configure() async throws

    /// Validate the destination configuration
    func validate() async throws -> Bool

    /// Test write to verify the destination works with encryption
    func testWrite() async throws -> Bool

    /// Run backup from source path
    /// - Parameters:
    ///   - source: Source directory path
    ///   - dryRun: If true, don't actually transfer files
    ///   - onProgress: Callback for progress updates
    func backup(
        source: String,
        dryRun: Bool,
        onProgress: @escaping @Sendable (SyncProgress) -> Void
    ) async throws
}

/// Configuration for a backup destination stored in the database
public struct BackupDestinationConfig: Sendable {
    public let name: String
    public let type: DestinationType
    public let bucketName: String
    public let remotePath: String

    /// Name of the 1Password item containing credentials
    public let onePasswordItemTitle: String

    /// Name of the 1Password vault
    public let onePasswordVault: String

    public init(
        name: String,
        type: DestinationType,
        bucketName: String,
        remotePath: String = "/",
        onePasswordItemTitle: String = "Immich Backup B2",
        onePasswordVault: String = "Private"
    ) {
        self.name = name
        self.type = type
        self.bucketName = bucketName
        self.remotePath = remotePath
        self.onePasswordItemTitle = onePasswordItemTitle
        self.onePasswordVault = onePasswordVault
    }

    /// Create config from database destination record
    public static func from(destination: Tracker.BackupDestination, vault: String = "Private", itemTitle: String = "Immich Backup B2") -> BackupDestinationConfig {
        return BackupDestinationConfig(
            name: destination.name,
            type: DestinationType(rawValue: destination.type) ?? .b2,
            bucketName: destination.bucketName,
            remotePath: destination.remotePath,
            onePasswordItemTitle: itemTitle,
            onePasswordVault: vault
        )
    }
}

/// Factory for creating backup destinations
public struct BackupDestinationFactory {
    /// Create a backup destination from configuration
    public static func create(
        config: BackupDestinationConfig,
        rclone: RcloneWrapper? = nil,
        onePassword: OnePasswordCLI? = nil
    ) -> any BackupDestinationProtocol {
        switch config.type {
        case .b2:
            return B2Destination(
                config: config,
                rclone: rclone ?? RcloneWrapper(),
                onePassword: onePassword ?? OnePasswordCLI()
            )
        }
    }
}
