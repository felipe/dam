import Foundation

/// Wrapper for 1Password CLI (op) operations
public actor OnePasswordCLI {
    /// Default op executable path
    private let opPath: String

    public init(opPath: String = "op") {
        self.opPath = opPath
    }

    // MARK: - Installation and Auth Checks

    /// Check if 1Password CLI is installed
    public func checkInstalled() async -> Bool {
        do {
            let (_, exitCode) = try await runCommand("/usr/bin/which", arguments: ["op"])
            return exitCode == 0
        } catch {
            return false
        }
    }

    /// Check if user is signed in to 1Password CLI
    public func checkSignedIn() async -> Bool {
        do {
            let (_, exitCode) = try await runCommand(opPath, arguments: ["account", "get", "--format", "json"])
            return exitCode == 0
        } catch {
            return false
        }
    }

    /// Get current account info
    public func getAccountInfo() async throws -> [String: Any] {
        let (output, exitCode) = try await runCommand(opPath, arguments: ["account", "get", "--format", "json"])

        guard exitCode == 0 else {
            throw BackupError.onePasswordNotSignedIn
        }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.onePasswordOperationFailed("Failed to parse account info")
        }

        return json
    }

    // MARK: - Item Operations

    /// Get an item from 1Password by vault and title
    /// Returns a dictionary of field labels to values
    public func getItem(vault: String, title: String) async throws -> [String: String] {
        let (output, exitCode) = try await runCommand(
            opPath,
            arguments: ["item", "get", title, "--vault", vault, "--format", "json"]
        )

        guard exitCode == 0 else {
            if output.contains("isn't an item") || output.contains("not found") {
                throw BackupError.onePasswordItemNotFound(title)
            }
            throw BackupError.onePasswordOperationFailed("Failed to get item: \(output)")
        }

        return try parseItemFields(from: output)
    }

    /// Check if an item exists in 1Password
    public func itemExists(vault: String, title: String) async -> Bool {
        do {
            _ = try await getItem(vault: vault, title: title)
            return true
        } catch BackupError.onePasswordItemNotFound {
            return false
        } catch {
            return false
        }
    }

    /// Create a new item in 1Password
    /// - Parameters:
    ///   - vault: Vault name
    ///   - title: Item title
    ///   - category: Item category (default: "Secure Note")
    ///   - fields: Dictionary of field names to values
    public func createItem(
        vault: String,
        title: String,
        category: String = "Secure Note",
        fields: [String: String]
    ) async throws {
        var arguments = [
            "item", "create",
            "--vault", vault,
            "--title", title,
            "--category", category
        ]

        // Add fields
        for (fieldName, fieldValue) in fields {
            // Format: "fieldName[type]=value"
            // Use "password" type for sensitive fields
            let fieldType = fieldName.lowercased().contains("password") ||
                           fieldName.lowercased().contains("key") ? "password" : "text"
            arguments.append("\(fieldName)[\(fieldType)]=\(fieldValue)")
        }

        let (output, exitCode) = try await runCommand(opPath, arguments: arguments)

        guard exitCode == 0 else {
            throw BackupError.onePasswordOperationFailed("Failed to create item: \(output)")
        }
    }

    /// Update an existing item's fields
    public func updateItem(
        vault: String,
        title: String,
        fields: [String: String]
    ) async throws {
        var arguments = ["item", "edit", title, "--vault", vault]

        for (fieldName, fieldValue) in fields {
            arguments.append("\(fieldName)=\(fieldValue)")
        }

        let (output, exitCode) = try await runCommand(opPath, arguments: arguments)

        guard exitCode == 0 else {
            throw BackupError.onePasswordOperationFailed("Failed to update item: \(output)")
        }
    }

    /// Delete an item from 1Password
    public func deleteItem(vault: String, title: String) async throws {
        let (output, exitCode) = try await runCommand(
            opPath,
            arguments: ["item", "delete", title, "--vault", vault]
        )

        guard exitCode == 0 else {
            throw BackupError.onePasswordOperationFailed("Failed to delete item: \(output)")
        }
    }

    // MARK: - Password Generation

    /// Generate a secure random password
    /// - Parameter length: Password length (default 32)
    /// - Returns: Generated password string
    public func generatePassword(length: Int = 32) async throws -> String {
        let (output, exitCode) = try await runCommand(
            opPath,
            arguments: ["generate", "password", "--length", "\(length)"]
        )

        guard exitCode == 0 else {
            throw BackupError.onePasswordOperationFailed("Failed to generate password: \(output)")
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vault Operations

    /// List available vaults
    public func listVaults() async throws -> [String] {
        let (output, exitCode) = try await runCommand(
            opPath,
            arguments: ["vault", "list", "--format", "json"]
        )

        guard exitCode == 0 else {
            throw BackupError.onePasswordOperationFailed("Failed to list vaults: \(output)")
        }

        guard let data = output.data(using: .utf8),
              let vaults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return vaults.compactMap { $0["name"] as? String }
    }

    // MARK: - Private Helpers

    private func runCommand(
        _ command: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()

        // Use /usr/bin/env to find the command in PATH
        if command == opPath {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Set up timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        // Combine stdout and stderr for error messages
        return (output.isEmpty ? errorOutput : output, process.terminationStatus)
    }

    /// Parse 1Password item JSON output into field dictionary
    private func parseItemFields(from jsonString: String) throws -> [String: String] {
        guard let data = jsonString.data(using: .utf8) else {
            throw BackupError.onePasswordOperationFailed("Invalid JSON encoding")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.onePasswordOperationFailed("Invalid JSON format")
        }

        var result: [String: String] = [:]

        // Parse fields array
        if let fields = json["fields"] as? [[String: Any]] {
            for field in fields {
                // Get field label (or id as fallback)
                let label = field["label"] as? String ?? field["id"] as? String ?? ""
                if label.isEmpty { continue }

                // Get field value
                if let value = field["value"] as? String {
                    result[label] = value
                }
            }
        }

        // Also check for common top-level fields
        if let notesSection = json["notes"] as? String, !notesSection.isEmpty {
            result["notes"] = notesSection
        }

        return result
    }
}

// MARK: - B2 Credential Structure

/// Expected structure for B2 credentials in 1Password
/// Item title: configurable (default "Immich Backup B2")
/// Fields:
///   - application_key_id: B2 Application Key ID
///   - application_key: B2 Application Key
///   - bucket_name: B2 Bucket name
///   - encryption_password: Password for rclone crypt encryption
public struct B2Credentials: Sendable {
    public let applicationKeyId: String
    public let applicationKey: String
    public let bucketName: String
    public let encryptionPassword: String

    public init(applicationKeyId: String, applicationKey: String, bucketName: String, encryptionPassword: String) {
        self.applicationKeyId = applicationKeyId
        self.applicationKey = applicationKey
        self.bucketName = bucketName
        self.encryptionPassword = encryptionPassword
    }

    /// Parse credentials from 1Password item fields
    public static func from(fields: [String: String]) throws -> B2Credentials {
        guard let keyId = fields["application_key_id"] ?? fields["applicationKeyId"] else {
            throw BackupError.credentialsNotFound("application_key_id field not found")
        }

        guard let key = fields["application_key"] ?? fields["applicationKey"] else {
            throw BackupError.credentialsNotFound("application_key field not found")
        }

        guard let bucket = fields["bucket_name"] ?? fields["bucketName"] else {
            throw BackupError.credentialsNotFound("bucket_name field not found")
        }

        guard let password = fields["encryption_password"] ?? fields["encryptionPassword"] else {
            throw BackupError.credentialsNotFound("encryption_password field not found")
        }

        return B2Credentials(
            applicationKeyId: keyId,
            applicationKey: key,
            bucketName: bucket,
            encryptionPassword: password
        )
    }

    /// Field names expected in 1Password item
    public static let requiredFields = [
        "application_key_id",
        "application_key",
        "bucket_name",
        "encryption_password"
    ]
}
