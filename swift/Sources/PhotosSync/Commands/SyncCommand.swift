import PhotosSyncLib
import ArgumentParser
import Foundation

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-tracker",
        abstract: "Sync local tracker database with Immich inventory"
    )
    
    func run() async throws {
        print("Syncing tracker with Immich...")
        
        guard let config = Config.load() else {
            throw ExitCode.failure
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
        let existingUUIDs = tracker.getImportedUUIDs()
        print("Tracker has \(formatNumber(existingUUIDs.count)) entries")
        
        // Fetch assets from Immich (both photos-sync and dam-icloud-drain)
        print("Fetching photos-sync assets from Immich...")
        let photosSyncAssets = await immich.getAllAssets(deviceId: "photos-sync") { count in
            print("  Fetched \(formatNumber(count)) photos-sync assets...")
        }
        print("Found \(formatNumber(photosSyncAssets.count)) photos-sync assets")
        
        print("Fetching dam-icloud-drain assets from Immich...")
        let drainAssets = await immich.getAllAssets(deviceId: "dam-icloud-drain") { count in
            print("  Fetched \(formatNumber(count)) dam-icloud-drain assets...")
        }
        print("Found \(formatNumber(drainAssets.count)) dam-icloud-drain assets")
        
        let immichAssets = photosSyncAssets + drainAssets
        print("Total: \(formatNumber(immichAssets.count)) assets to sync")
        
        // Find assets not in tracker
        var added = 0
        var skipped = 0
        
        for asset in immichAssets {
            // deviceAssetId format: "UUID/L0/001" - extract just the UUID part
            let uuid = asset.deviceAssetId
            
            if existingUUIDs.contains(uuid) {
                skipped += 1
                continue
            }
            
            // Add to tracker with default subtypes (unknown from Immich)
            let mediaType = asset.type == "VIDEO" ? "video" : "photo"
            do {
                try tracker.markImported(
                    uuid: uuid,
                    immichID: asset.id,
                    filename: asset.originalFileName,
                    fileSize: asset.fileSize,
                    mediaType: mediaType,
                    subtypes: .none,
                    motionVideoImmichID: nil
                )
                added += 1
            } catch {
                print("  Error adding \(asset.originalFileName): \(error)")
            }
        }
        
        print()
        print("Sync complete:")
        print("  Already tracked: \(formatNumber(skipped))")
        print("  Added to tracker: \(formatNumber(added))")
        print("  Total in tracker: \(formatNumber(existingUUIDs.count + added))")
    }
    
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
