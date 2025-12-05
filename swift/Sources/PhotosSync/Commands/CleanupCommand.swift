import PhotosSyncLib
import ArgumentParser
import Foundation
import Photos

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Sync deletions between Photos and Immich (Immich is source of truth)"
    )
    
    @Flag(name: .long, help: "Preview what would be changed without making changes")
    var dryRun: Bool = false
    
    @Option(name: .long, help: "Maximum number of items to process (0 = unlimited)")
    var limit: Int = 0
    
    @Flag(name: .long, help: "Skip confirmation prompt for bulk operations")
    var force: Bool = false
    
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
        
        // Get current Photos library UUIDs
        print("Fetching Photos library...")
        let photosAssets = PhotosFetcher.getAllAssets()
        let photosUUIDs = Set(photosAssets.map { $0.localIdentifier })
        print("Assets in Photos: \(formatNumber(photosUUIDs.count))")
        
        // Build a map of Photos assets for Live Photo detection
        let photosAssetMap = Dictionary(uniqueKeysWithValues: photosAssets.map { ($0.localIdentifier, $0) })
        
        // === PART 1: Deleted from Immich → Delete from Photos ===
        var toDeleteFromPhotos: [(uuid: String, immichID: String)] = []
        var skippedLivePhotos = 0  // Live Photos without motion video backup
        
        for uuid in importedUUIDs {
            if let immichID = tracker.getImmichIDForUUID(uuid) {
                if !immichAssetIDs.contains(immichID) {
                    // This was imported but no longer exists in Immich
                    
                    // SAFETY CHECK: For Live Photos, ensure motion video is backed up
                    if let asset = photosAssetMap[uuid], asset.isLivePhoto {
                        // Check if we have the motion video backed up
                        if !tracker.hasMotionVideoBackup(uuid: uuid) {
                            // Skip this Live Photo - motion video not backed up
                            // Deleting it would lose the motion video forever
                            skippedLivePhotos += 1
                            continue
                        }
                    }
                    
                    // Also check tracker's Live Photo status for assets not in Photos library
                    if tracker.isLivePhoto(uuid: uuid) && !tracker.hasMotionVideoBackup(uuid: uuid) {
                        skippedLivePhotos += 1
                        continue
                    }
                    
                    toDeleteFromPhotos.append((uuid: uuid, immichID: immichID))
                }
            }
        }
        
        // === PART 2: Deleted from Photos → Archive in Immich ===
        var toArchiveInImmich: [(uuid: String, immichID: String)] = []
        
        for uuid in importedUUIDs {
            // Skip already archived
            if tracker.isArchived(uuid: uuid) {
                continue
            }
            
            if let immichID = tracker.getImmichIDForUUID(uuid) {
                // Check if it still exists in Immich but not in Photos
                if immichAssetIDs.contains(immichID) && !photosUUIDs.contains(uuid) {
                    toArchiveInImmich.append((uuid: uuid, immichID: immichID))
                }
            }
        }
        
        // Apply limits
        if limit > 0 {
            if toDeleteFromPhotos.count > limit {
                toDeleteFromPhotos = Array(toDeleteFromPhotos.prefix(limit))
            }
            if toArchiveInImmich.count > limit {
                toArchiveInImmich = Array(toArchiveInImmich.prefix(limit))
            }
        }
        
        print()
        print(String(repeating: "=", count: 60))
        print("CLEANUP SUMMARY")
        print(String(repeating: "=", count: 60))
        print("Delete from Photos (removed in Immich): \(formatNumber(toDeleteFromPhotos.count))")
        print("Archive in Immich (removed in Photos):  \(formatNumber(toArchiveInImmich.count))")
        if skippedLivePhotos > 0 {
            print("Skipped Live Photos (no motion video):  \(formatNumber(skippedLivePhotos))")
            print("  Run 'import --repair-live-photos' first to backup motion videos")
        }
        print()
        
        if toDeleteFromPhotos.isEmpty && toArchiveInImmich.isEmpty {
            print("Nothing to clean up. Everything is in sync!")
            return
        }
        
        // === Process deletions from Photos ===
        if !toDeleteFromPhotos.isEmpty {
            print()
            print("--- DELETE FROM PHOTOS ---")
            print("These assets were deleted/deduped in Immich.")
            print("They will be moved to Recently Deleted in Photos.")
            print()
            
            if dryRun {
                print("Would delete \(formatNumber(toDeleteFromPhotos.count)) assets:")
                for item in toDeleteFromPhotos.prefix(10) {
                    print("  - \(item.uuid)")
                }
                if toDeleteFromPhotos.count > 10 {
                    print("  ... and \(toDeleteFromPhotos.count - 10) more")
                }
            } else {
                // Confirm for bulk deletions
                if toDeleteFromPhotos.count > 10 && !force {
                    print("About to delete \(formatNumber(toDeleteFromPhotos.count)) assets.")
                    print("Press Enter to continue or Ctrl+C to cancel...")
                    _ = readLine()
                }
                
                var deleted = 0
                var failed = 0
                
                let batchSize = 50
                for batchStart in stride(from: 0, to: toDeleteFromPhotos.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, toDeleteFromPhotos.count)
                    let batch = Array(toDeleteFromPhotos[batchStart..<batchEnd])
                    let uuids = batch.map { $0.uuid }
                    
                    print("Deleting batch \(batchStart/batchSize + 1)/\((toDeleteFromPhotos.count + batchSize - 1)/batchSize)...")
                    
                    let results = await PhotosDeleter.deleteAssets(identifiers: uuids, dryRun: false)
                    
                    for (idx, result) in results.enumerated() {
                        if result.success {
                            deleted += 1
                            // Remove from tracker since it's gone from both places
                            try? tracker.removeAsset(uuid: batch[idx].uuid)
                        } else {
                            print("  Failed: \(result.localIdentifier): \(result.error ?? "unknown")")
                            failed += 1
                        }
                    }
                }
                
                print("Deleted: \(formatNumber(deleted)), Failed: \(formatNumber(failed))")
            }
        }
        
        // === Process archives in Immich ===
        if !toArchiveInImmich.isEmpty {
            print()
            print("--- ARCHIVE IN IMMICH ---")
            print("These assets were deleted from Photos but exist in Immich.")
            print("They will be archived (hidden) in Immich to prevent re-upload.")
            print()
            
            if dryRun {
                print("Would archive \(formatNumber(toArchiveInImmich.count)) assets:")
                for item in toArchiveInImmich.prefix(10) {
                    print("  - \(item.uuid) → \(item.immichID)")
                }
                if toArchiveInImmich.count > 10 {
                    print("  ... and \(toArchiveInImmich.count - 10) more")
                }
            } else {
                // Confirm for bulk archives
                if toArchiveInImmich.count > 10 && !force {
                    print("About to archive \(formatNumber(toArchiveInImmich.count)) assets.")
                    print("Press Enter to continue or Ctrl+C to cancel...")
                    _ = readLine()
                }
                
                var archived = 0
                var failed = 0
                
                // Archive in batches
                let batchSize = 50
                for batchStart in stride(from: 0, to: toArchiveInImmich.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, toArchiveInImmich.count)
                    let batch = Array(toArchiveInImmich[batchStart..<batchEnd])
                    let immichIDs = batch.map { $0.immichID }
                    
                    print("Archiving batch \(batchStart/batchSize + 1)/\((toArchiveInImmich.count + batchSize - 1)/batchSize)...")
                    
                    let success = await immich.archiveAssets(ids: immichIDs)
                    
                    if success {
                        for item in batch {
                            try? tracker.markArchived(uuid: item.uuid)
                            archived += 1
                        }
                    } else {
                        print("  Failed to archive batch")
                        failed += batch.count
                    }
                }
                
                print("Archived: \(formatNumber(archived)), Failed: \(formatNumber(failed))")
            }
        }
        
        print()
        print(String(repeating: "=", count: 60))
        print("CLEANUP COMPLETE")
        print(String(repeating: "=", count: 60))
        if !dryRun {
            print("Note: Deleted Photos are in 'Recently Deleted' for 30 days")
        }
    }
    
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
