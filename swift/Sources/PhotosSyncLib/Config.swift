import Foundation

public struct Config: Sendable {
    public let immichURL: String
    public let immichAPIKey: String
    public let stagingDir: URL
    public let dataDir: URL
    public let batchSize: Int
    public let dryRun: Bool
    
    public var trackerDBPath: URL {
        dataDir.appendingPathComponent("tracker.db")
    }
    
    public static func load(dryRun: Bool = false, batchSize: Int = 100) -> Config? {
        // Find .env file - look in dam directory
        let damDir = findDAMDirectory()
        let envPath = damDir.appendingPathComponent(".env")
        
        guard let envContents = try? String(contentsOf: envPath, encoding: .utf8) else {
            print("ERROR: Could not read .env file at \(envPath.path)")
            return nil
        }
        
        var env: [String: String] = [:]
        for line in envContents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                env[key] = value
            }
        }
        
        guard let immichURL = env["IMMICH_URL"],
              let immichAPIKey = env["IMMICH_API_KEY"] else {
            print("ERROR: IMMICH_URL and IMMICH_API_KEY required in .env")
            return nil
        }
        
        let stagingDir = URL(fileURLWithPath: env["STAGING_DIR"] ?? "/tmp/dam-staging")
        let dataDir = damDir.appendingPathComponent("data")
        
        // Ensure directories exist
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        
        return Config(
            immichURL: immichURL,
            immichAPIKey: immichAPIKey,
            stagingDir: stagingDir,
            dataDir: dataDir,
            batchSize: batchSize,
            dryRun: dryRun
        )
    }
    
    private static func findDAMDirectory() -> URL {
        // Start from executable location and walk up to find dam directory
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        
        // Check if we're already in dam or a subdirectory
        while url.path != "/" {
            if url.lastPathComponent == "dam" {
                return url
            }
            // Check if dam exists as subdirectory
            let damPath = url.appendingPathComponent("dam")
            if FileManager.default.fileExists(atPath: damPath.path) {
                return damPath
            }
            url = url.deletingLastPathComponent()
        }
        
        // Fallback to hardcoded path
        return URL(fileURLWithPath: "/Users/felipe/Projects/felipe/dam")
    }
}
