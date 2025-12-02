import ArgumentParser
import Foundation
import Photos

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Delete photos from Photos.app that have been removed from Immich"
    )
    
    @Flag(name: .long, help: "Preview what would be deleted without making changes")
    var dryRun: Bool = false
    
    @Option(name: .long, help: "Maximum number of photos to delete (0 = unlimited)")
    var limit: Int = 0
    
    func run() async throws {
        print("Requesting Photos access...")
        guard await PhotosFetcher.requestAccess() else {
            print("ERROR: Photos access denied. Grant access in System Settings → Privacy → Photos")
            throw ExitCode.failure
        }
        
        guard let config = Config.load(dryRun: dryRun) else {
            throw ExitCode.failure
        }
        
        if dryRun {
            print("DRY RUN MODE - No changes will be made")
            print()
        }
        
        // Connect to Immich
        let immich = ImmichClient(baseURL: config.immichURL, apiKey: config.immichAPIKey)
        print("Connecting to Immich at \(config.immichURL)...")
        guard await immich.ping() else {
            print("ERROR: Could not connect to Immich")
            throw ExitCode.failure
        }
        print("Connected to Immich")
        
        // Load tracker
        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let importedUUIDs = tracker.getImportedUUIDs()
        print("Tracked imports: \(formatNumber(importedUUIDs.count))")
        
        // Get all asset IDs currently in Immich
        print("Fetching Immich asset list...")
        let immichAssetIDs = await immich.getAllAssetIDs()
        print("Assets in Immich: \(formatNumber(immichAssetIDs.count))")
        
        // Find imports that are no longer in Immich (deleted/deduped)
        var toDelete: [(uuid: String, immichID: String?)] = []
        
        for uuid in importedUUIDs {
            if let immichID = tracker.getImmichIDForUUID(uuid) {
                if !immichAssetIDs.contains(immichID) {
                    // This was imported but no longer exists in Immich
                    toDelete.append((uuid: uuid, immichID: immichID))
                }
            }
        }
        
        // Apply limit
        if limit > 0 && toDelete.count > limit {
            toDelete = Array(toDelete.prefix(limit))
        }
        
        print("Assets to delete from Photos: \(formatNumber(toDelete.count))")
        
        if toDelete.isEmpty {
            print("Nothing to clean up.")
            return
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("CLEANUP - DELETE \(formatNumber(toDelete.count)) ASSETS")
        print(String(repeating: "=", count: 50))
        print()
        print("These photos were imported to Immich but have since been deleted")
        print("(likely as duplicates). They will be moved to Recently Deleted.")
        print()
        
        if dryRun {
            print("Would delete \(formatNumber(toDelete.count)) assets from Photos.app")
            for item in toDelete.prefix(10) {
                print("  - \(item.uuid)")
            }
            if toDelete.count > 10 {
                print("  ... and \(toDelete.count - 10) more")
            }
            return
        }
        
        // Confirm before deleting
        print("Press Enter to continue or Ctrl+C to cancel...")
        _ = readLine()
        
        var deleted = 0
        var failed = 0
        
        // Delete in batches of 50
        let batchSize = 50
        for batchStart in stride(from: 0, to: toDelete.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, toDelete.count)
            let batch = Array(toDelete[batchStart..<batchEnd])
            let uuids = batch.map { $0.uuid }
            
            print("Deleting batch \(batchStart/batchSize + 1)...")
            
            let results = await PhotosDeleter.deleteAssets(identifiers: uuids, dryRun: false)
            
            for result in results {
                if result.success {
                    deleted += 1
                } else {
                    print("  Failed to delete \(result.localIdentifier): \(result.error ?? "unknown")")
                    failed += 1
                }
            }
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("CLEANUP COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Deleted: \(formatNumber(deleted))")
        print("Failed:  \(formatNumber(failed))")
        print()
        print("Note: Deleted photos are in 'Recently Deleted' for 30 days")
    }
    
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
