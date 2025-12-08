import Foundation

/// Backblaze B2 backup destination implementation
/// Uses rclone with crypt overlay for encrypted backups
///
/// Remote configuration:
/// - Base remote: `{name}-b2` - Backblaze B2 backend
/// - Crypt remote: `{name}-crypt` - Encryption overlay on top of B2
///
/// 1Password item structure (default title: "Immich Backup B2"):
/// - application_key_id: B2 Application Key ID
/// - application_key: B2 Application Key
/// - bucket_name: B2 Bucket name
/// - encryption_password: Password for rclone crypt encryption
public actor B2Destination: BackupDestinationProtocol {
    public let name: String
    public let type: DestinationType = .b2

    private let config: BackupDestinationConfig
    private let rclone: RcloneWrapper
    private let onePassword: OnePasswordCLI

    /// Name of the B2 rclone remote
    private var b2RemoteName: String {
        "\(name)-b2"
    }

    /// Name of the crypt rclone remote (encryption overlay)
    private var cryptRemoteName: String {
        "\(name)-crypt"
    }

    public init(
        config: BackupDestinationConfig,
        rclone: RcloneWrapper = RcloneWrapper(),
        onePassword: OnePasswordCLI = OnePasswordCLI()
    ) {
        self.name = config.name
        self.config = config
        self.rclone = rclone
        self.onePassword = onePassword
    }

    // MARK: - Credential Loading

    /// Load B2 credentials from 1Password
    public func loadCredentials() async throws -> B2Credentials {
        // Check 1Password is available
        guard await onePassword.checkSignedIn() else {
            throw BackupError.onePasswordNotSignedIn
        }

        // Get the item
        let fields = try await onePassword.getItem(
            vault: config.onePasswordVault,
            title: config.onePasswordItemTitle
        )

        // Parse credentials
        return try B2Credentials.from(fields: fields)
    }

    // MARK: - BackupDestinationProtocol Implementation

    /// Configure rclone remotes for B2 with encryption
    public func configure() async throws {
        // Load credentials from 1Password
        let credentials = try await loadCredentials()

        // Check if rclone is installed
        guard await rclone.checkInstalled() else {
            throw BackupError.rcloneNotInstalled
        }

        // Configure B2 remote
        try await configureB2Remote(credentials: credentials)

        // Configure crypt overlay
        try await configureCryptRemote(
            encryptionPassword: credentials.encryptionPassword,
            remotePath: config.remotePath
        )
    }

    /// Validate the destination configuration
    public func validate() async throws -> Bool {
        // Check rclone is installed
        guard await rclone.checkInstalled() else {
            throw BackupError.rcloneNotInstalled
        }

        // Check 1Password is signed in
        guard await onePassword.checkSignedIn() else {
            throw BackupError.onePasswordNotSignedIn
        }

        // Check credentials exist
        _ = try await loadCredentials()

        // Check remotes are configured
        let remotes = try await rclone.listRemotes()
        guard remotes.contains(b2RemoteName) else {
            throw BackupError.rcloneConfigFailed("B2 remote '\(b2RemoteName)' not configured")
        }
        guard remotes.contains(cryptRemoteName) else {
            throw BackupError.rcloneConfigFailed("Crypt remote '\(cryptRemoteName)' not configured")
        }

        // Test connection to B2
        let connectionOK = try await rclone.testConnection(remote: b2RemoteName)
        guard connectionOK else {
            throw BackupError.rcloneTestFailed("Connection to B2 failed")
        }

        return true
    }

    /// Test write to verify encryption works end-to-end
    public func testWrite() async throws -> Bool {
        let testContent = "B2 encryption test - \(Date().ISO8601Format())"
        let testFileName = ".backup_test_\(UUID().uuidString)"

        // Create a temporary local file
        let tempDir = FileManager.default.temporaryDirectory
        let localFile = tempDir.appendingPathComponent(testFileName)

        try testContent.write(to: localFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localFile) }

        // Upload via the crypt remote (this encrypts the file)
        let cryptDest = "\(cryptRemoteName):\(testFileName)"

        // Use rclone copyto command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rclone", "copyto", localFile.path, cryptDest]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw BackupError.testWriteFailed("Upload failed: \(errorOutput)")
        }

        // Verify file exists in crypt remote (which means it's in B2, encrypted)
        let verifyProcess = Process()
        verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        verifyProcess.arguments = ["rclone", "lsf", cryptDest]

        let verifyPipe = Pipe()
        verifyProcess.standardOutput = verifyPipe
        verifyProcess.standardError = Pipe()

        try verifyProcess.run()
        verifyProcess.waitUntilExit()

        // Clean up the test file
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cleanupProcess.arguments = ["rclone", "deletefile", cryptDest]

        try? cleanupProcess.run()
        cleanupProcess.waitUntilExit()

        return verifyProcess.terminationStatus == 0
    }

    /// Run backup from source to encrypted B2
    public func backup(
        source: String,
        dryRun: Bool,
        onProgress: @escaping @Sendable (SyncProgress) -> Void
    ) async throws {
        // Destination is the crypt remote (auto-encrypts)
        let destination = "\(cryptRemoteName):"

        // Run the sync
        let stream = try await rclone.sync(
            source: source,
            destination: destination,
            dryRun: dryRun,
            statsInterval: 60
        )

        // Process progress updates
        for try await progress in stream {
            onProgress(progress)
        }
    }

    // MARK: - Private Configuration Methods

    /// Configure the base B2 remote
    private func configureB2Remote(credentials: B2Credentials) async throws {
        // Delete existing remote if present
        let existingRemotes = try await rclone.listRemotes()
        if existingRemotes.contains(b2RemoteName) {
            try await rclone.deleteRemote(name: b2RemoteName)
        }

        // Create B2 remote
        // rclone config create NAME b2 account=KEYID key=KEY
        try await rclone.configureRemote(
            name: b2RemoteName,
            type: "b2",
            config: [
                "account": credentials.applicationKeyId,
                "key": credentials.applicationKey
            ]
        )
    }

    /// Configure the crypt overlay remote
    private func configureCryptRemote(encryptionPassword: String, remotePath: String) async throws {
        // Delete existing remote if present
        let existingRemotes = try await rclone.listRemotes()
        if existingRemotes.contains(cryptRemoteName) {
            try await rclone.deleteRemote(name: cryptRemoteName)
        }

        // The crypt remote wraps the B2 remote with encryption
        // Remote path format: b2remote:bucket/path
        let cryptTarget = "\(b2RemoteName):\(config.bucketName)\(remotePath)"

        // Create crypt remote
        // rclone config create NAME crypt remote=TARGET password=PASS filename_encryption=standard
        try await rclone.configureRemote(
            name: cryptRemoteName,
            type: "crypt",
            config: [
                "remote": cryptTarget,
                "password": encryptionPassword,
                "filename_encryption": "standard",
                "directory_name_encryption": "true"
            ]
        )
    }

    // MARK: - Utility Methods

    /// Get information about the current configuration
    public func getInfo() async throws -> B2DestinationInfo {
        let credentials = try await loadCredentials()

        return B2DestinationInfo(
            name: name,
            bucketName: credentials.bucketName,
            remotePath: config.remotePath,
            b2RemoteName: b2RemoteName,
            cryptRemoteName: cryptRemoteName,
            onePasswordItem: config.onePasswordItemTitle
        )
    }
}

/// Information about a B2 destination configuration
public struct B2DestinationInfo: Sendable {
    public let name: String
    public let bucketName: String
    public let remotePath: String
    public let b2RemoteName: String
    public let cryptRemoteName: String
    public let onePasswordItem: String
}
