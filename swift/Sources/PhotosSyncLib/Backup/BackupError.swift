import Foundation

/// Errors related to backup operations
public enum BackupError: Error, Sendable {
    // External tool errors
    case rcloneNotInstalled
    case rcloneConfigFailed(String)
    case rcloneSyncFailed(String)
    case rcloneTestFailed(String)

    case onePasswordNotInstalled
    case onePasswordNotSignedIn
    case onePasswordItemNotFound(String)
    case onePasswordOperationFailed(String)

    // Configuration errors
    case missingBackupPath
    case invalidDestination(String)
    case destinationNotFound(String)

    // Backup operation errors
    case backupFailed(String)
    case testWriteFailed(String)
    case credentialsNotFound(String)
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rcloneNotInstalled:
            return "rclone is not installed. Install with: brew install rclone"
        case .rcloneConfigFailed(let reason):
            return "rclone configuration failed: \(reason)"
        case .rcloneSyncFailed(let reason):
            return "rclone sync failed: \(reason)"
        case .rcloneTestFailed(let reason):
            return "rclone connection test failed: \(reason)"

        case .onePasswordNotInstalled:
            return "1Password CLI is not installed. Install with: brew install 1password-cli"
        case .onePasswordNotSignedIn:
            return "Not signed in to 1Password CLI. Run: op signin"
        case .onePasswordItemNotFound(let title):
            return "1Password item not found: \(title)"
        case .onePasswordOperationFailed(let reason):
            return "1Password operation failed: \(reason)"

        case .missingBackupPath:
            return "BACKUP_IMMICH_PATH not configured in .env"
        case .invalidDestination(let reason):
            return "Invalid backup destination: \(reason)"
        case .destinationNotFound(let name):
            return "Backup destination not found: \(name)"

        case .backupFailed(let reason):
            return "Backup failed: \(reason)"
        case .testWriteFailed(let reason):
            return "Test write verification failed: \(reason)"
        case .credentialsNotFound(let reason):
            return "Credentials not found: \(reason)"
        }
    }
}
