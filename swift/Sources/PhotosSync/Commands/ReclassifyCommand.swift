import PhotosSyncLib
import ArgumentParser
import Foundation
import Photos

struct ReclassifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclassify",
        abstract: "Update tracker database with current Photos library subtype information"
    )
    
    @Flag(name: .long, help: "Preview what would be changed without making changes")
    var dryRun: Bool = false
    
    @Flag(name: .long, help: "Also repair assets with paired video that are missing motion video backup")
    var repair: Bool = false
    
    @Option(name: .long, help: "Maximum number of repairs to process (0 = unlimited)")
    var repairLimit: Int = 0
    
    @Flag(name: .long, help: "Include photos that need to be downloaded from iCloud for repair")
    var includeCloud: Bool = false
    
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
        
        // Load tracker
        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let importedUUIDs = tracker.getImportedUUIDs()
        print("Tracked assets: \(formatNumber(importedUUIDs.count))")
        
        // Get all assets from Photos library
        print("Loading Photos library...")
        let allAssets = PhotosFetcher.getAllAssets()
        print("Assets in Photos: \(formatNumber(allAssets.count))")
        
        // Build lookup map
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        
        // Find tracked assets that exist in Photos library
        var updated = 0
        var notInLibrary = 0
        var needsPairedVideoRepair: [(uuid: String, asset: PhotosFetcher.AssetInfo)] = []
        
        // Subtype counters
        var subtypeCounts = SubtypeCounts()
        
        print()
        print("Scanning tracked assets for reclassification...")
        
        for (index, uuid) in importedUUIDs.enumerated() {
            if index % 5000 == 0 && index > 0 {
                print("  Processed \(formatNumber(index))/\(formatNumber(importedUUIDs.count))...")
            }
            
            guard let asset = assetMap[uuid] else {
                notInLibrary += 1
                continue
            }
            
            // Count subtypes
            if asset.isLivePhoto { subtypeCounts.livePhoto += 1 }
            if asset.isPortrait { subtypeCounts.portrait += 1 }
            if asset.isHDR { subtypeCounts.hdr += 1 }
            if asset.isPanorama { subtypeCounts.panorama += 1 }
            if asset.isScreenshot { subtypeCounts.screenshot += 1 }
            if asset.isCinematic { subtypeCounts.cinematic += 1 }
            if asset.isSlomo { subtypeCounts.slomo += 1 }
            if asset.isTimelapse { subtypeCounts.timelapse += 1 }
            if asset.isSpatialVideo { subtypeCounts.spatialVideo += 1 }
            if asset.isProRAW { subtypeCounts.proraw += 1 }
            if asset.hasPairedVideo { subtypeCounts.hasPairedVideo += 1 }
            
            // Check if needs repair (has paired video but no backup)
            if asset.hasPairedVideo && !tracker.hasMotionVideoBackup(uuid: uuid) {
                needsPairedVideoRepair.append((uuid, asset))
            }
            
            // Update the tracker with correct subtype info
            if !dryRun {
                let subtypes = Tracker.AssetSubtypes(
                    isLivePhoto: asset.isLivePhoto,
                    isPortrait: asset.isPortrait,
                    isHDR: asset.isHDR,
                    isPanorama: asset.isPanorama,
                    isScreenshot: asset.isScreenshot,
                    isCinematic: asset.isCinematic,
                    isSlomo: asset.isSlomo,
                    isTimelapse: asset.isTimelapse,
                    isSpatialVideo: asset.isSpatialVideo,
                    isProRAW: asset.isProRAW,
                    hasPairedVideo: asset.hasPairedVideo
                )
                
                // Update just the subtype columns (preserve other data)
                do {
                    try tracker.updateSubtypes(uuid: uuid, subtypes: subtypes)
                    updated += 1
                } catch {
                    // Ignore errors - asset might have been deleted
                }
            } else {
                updated += 1
            }
        }
        
        // Print results
        print()
        print(String(repeating: "=", count: 60))
        print("RECLASSIFICATION RESULTS")
        print(String(repeating: "=", count: 60))
        print()
        print("Assets processed: \(formatNumber(updated))")
        print("Not in library:   \(formatNumber(notInLibrary))")
        print()
        print("Subtypes found:")
        print("  Live Photo:     \(formatNumber(subtypeCounts.livePhoto))")
        print("  Portrait:       \(formatNumber(subtypeCounts.portrait))")
        print("  HDR:            \(formatNumber(subtypeCounts.hdr))")
        print("  Panorama:       \(formatNumber(subtypeCounts.panorama))")
        print("  Screenshot:     \(formatNumber(subtypeCounts.screenshot))")
        print("  Cinematic:      \(formatNumber(subtypeCounts.cinematic))")
        print("  Slo-mo:         \(formatNumber(subtypeCounts.slomo))")
        print("  Timelapse:      \(formatNumber(subtypeCounts.timelapse))")
        print("  Spatial Video:  \(formatNumber(subtypeCounts.spatialVideo))")
        print("  ProRAW:         \(formatNumber(subtypeCounts.proraw))")
        print("  Has Paired Video: \(formatNumber(subtypeCounts.hasPairedVideo))")
        print()
        
        // Analyze paired video repair needs
        let livePhotoNeedingRepair = needsPairedVideoRepair.filter { $0.asset.isLivePhoto }
        let nonLiveNeedingRepair = needsPairedVideoRepair.filter { !$0.asset.isLivePhoto }
        
        print("Paired video repair needed:")
        print("  Live Photos:      \(formatNumber(livePhotoNeedingRepair.count))")
        print("  Non-Live assets:  \(formatNumber(nonLiveNeedingRepair.count))")
        
        // Break down non-Live by subtype
        if !nonLiveNeedingRepair.isEmpty {
            print()
            print("  Non-Live breakdown:")
            let slomoCount = nonLiveNeedingRepair.filter { $0.asset.isSlomo }.count
            let corruptedCount = nonLiveNeedingRepair.filter { !$0.asset.isSlomo && !$0.asset.isLivePhoto }.count
            print("    Slo-mo photos:      \(formatNumber(slomoCount))")
            print("    Corrupted (no subtype): \(formatNumber(corruptedCount))")
            
            // Show a few examples of corrupted
            let corrupted = nonLiveNeedingRepair.filter { !$0.asset.isSlomo && !$0.asset.isLivePhoto }
            if !corrupted.isEmpty {
                print()
                print("  Corrupted Live Photos (lost subtype flag):")
                for item in corrupted.prefix(5) {
                    print("    - \(item.asset.filename)")
                }
                if corrupted.count > 5 {
                    print("    ... and \(corrupted.count - 5) more")
                }
            }
        }
        
        // Run repair if requested
        if repair && !needsPairedVideoRepair.isEmpty {
            try await runRepair(
                assets: needsPairedVideoRepair,
                config: config,
                tracker: tracker,
                limit: repairLimit,
                dryRun: dryRun,
                allowNetwork: includeCloud
            )
        } else if !needsPairedVideoRepair.isEmpty {
            print()
            print("To repair paired video assets, run:")
            print("  photos-sync reclassify --repair")
        }
        
        if dryRun {
            print()
            print("DRY RUN - No changes were made")
        }
    }
    
    private func runRepair(
        assets: [(uuid: String, asset: PhotosFetcher.AssetInfo)],
        config: Config,
        tracker: Tracker,
        limit: Int,
        dryRun: Bool,
        allowNetwork: Bool
    ) async throws {
        // Connect to Immich
        let immich = ImmichClient(baseURL: config.immichURL, apiKey: config.immichAPIKey)
        print()
        print("Connecting to Immich at \(config.immichURL)...")
        guard await immich.ping() else {
            print("ERROR: Could not connect to Immich")
            throw ExitCode.failure
        }
        print("Connected to Immich")
        
        // Filter out Cinematic
        var toRepair = assets.filter { !$0.asset.isCinematic }
        
        // Apply limit
        if limit > 0 && toRepair.count > limit {
            toRepair = Array(toRepair.prefix(limit))
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("REPAIRING \(formatNumber(toRepair.count)) PAIRED VIDEO ASSETS")
        print(String(repeating: "=", count: 50))
        print()
        
        var repaired = 0
        var failed = 0
        var skipped = 0
        
        for (index, item) in toRepair.enumerated() {
            let num = index + 1
            var labels: [String] = []
            if item.asset.isLivePhoto { labels.append("Live") }
            if item.asset.isSlomo { labels.append("Slomo") }
            if labels.isEmpty { labels.append("Corrupted") }
            let labelStr = "[\(labels.joined(separator: ", "))]"
            
            print("[\(num)/\(toRepair.count)] \(item.asset.filename) \(labelStr)")
            
            if dryRun {
                print("  DRY RUN: Would repair")
                skipped += 1
                continue
            }
            
            // Check if asset has paired video resource
            guard PhotosFetcher.hasPairedVideoResource(identifier: item.uuid) else {
                print("  WARNING: No paired video in Photos library")
                try? tracker.updatePairedVideoInfo(uuid: item.uuid, hasPairedVideo: false, motionVideoImmichID: nil)
                skipped += 1
                continue
            }
            
            // Download the paired asset
            print("  Exporting image + video...")
            let result = await PhotosFetcher.downloadPairedAsset(
                identifier: item.uuid,
                to: config.stagingDir,
                allowNetwork: allowNetwork
            )
            
            guard result.success, let imageURL = result.imageResult.fileURL else {
                print("  ERROR: \(result.imageResult.error ?? "Export failed")")
                failed += 1
                continue
            }
            
            guard result.hasVideo, let videoResult = result.videoResult, let videoURL = videoResult.fileURL else {
                print("  ERROR: No paired video found")
                try? FileManager.default.removeItem(at: imageURL)
                failed += 1
                continue
            }
            
            print("  Image: \(formatBytes(result.imageResult.fileSize)), Video: \(formatBytes(videoResult.fileSize))")
            
            // Get dates
            let dates = PhotosFetcher.getAssetDates(identifier: item.uuid)
            
            // Upload video first
            let videoDeviceID = "\(item.uuid)_video"
            let videoUploadResult = await immich.uploadAsset(
                fileURL: videoURL,
                deviceAssetID: videoDeviceID,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified
            )
            
            try? FileManager.default.removeItem(at: videoURL)
            
            guard videoUploadResult.success, let videoImmichID = videoUploadResult.assetID else {
                print("  ERROR: Video upload failed: \(videoUploadResult.error ?? "unknown")")
                try? FileManager.default.removeItem(at: imageURL)
                failed += 1
                continue
            }
            
            if videoUploadResult.duplicate {
                print("  Video: duplicate")
            } else {
                print("  Video uploaded: \(videoImmichID)")
            }
            
            // Delete old image from Immich if exists
            if let oldImmichID = tracker.getImmichIDForUUID(item.uuid) {
                let deleteResult = await immich.deleteAssets(ids: [oldImmichID], force: true)
                if deleteResult.success {
                    print("  Deleted old asset from Immich")
                }
            }
            
            // Upload new image linked to video
            let imageUploadResult = await immich.uploadAsset(
                fileURL: imageURL,
                deviceAssetID: item.uuid,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified,
                livePhotoVideoId: videoImmichID
            )
            
            try? FileManager.default.removeItem(at: imageURL)
            
            if imageUploadResult.success {
                print("  Image uploaded: \(imageUploadResult.assetID ?? "unknown") (linked)")
                
                // Update tracker
                let subtypes = Tracker.AssetSubtypes(
                    isLivePhoto: item.asset.isLivePhoto,
                    isPortrait: item.asset.isPortrait,
                    isHDR: item.asset.isHDR,
                    isPanorama: item.asset.isPanorama,
                    isScreenshot: item.asset.isScreenshot,
                    isCinematic: item.asset.isCinematic,
                    isSlomo: item.asset.isSlomo,
                    isTimelapse: item.asset.isTimelapse,
                    isSpatialVideo: item.asset.isSpatialVideo,
                    isProRAW: item.asset.isProRAW,
                    hasPairedVideo: item.asset.hasPairedVideo
                )
                try? tracker.markImported(
                    uuid: item.uuid,
                    immichID: imageUploadResult.assetID,
                    filename: result.imageResult.filename,
                    fileSize: result.imageResult.fileSize,
                    mediaType: result.imageResult.mediaType,
                    subtypes: subtypes,
                    motionVideoImmichID: videoImmichID
                )
                repaired += 1
            } else {
                print("  ERROR: Image upload failed: \(imageUploadResult.error ?? "unknown")")
                failed += 1
            }
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("REPAIR COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Repaired: \(formatNumber(repaired))")
        print("Failed:   \(formatNumber(failed))")
        if dryRun {
            print("Skipped:  \(formatNumber(skipped)) (dry run)")
        }
    }
    
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct SubtypeCounts {
    var livePhoto = 0
    var portrait = 0
    var hdr = 0
    var panorama = 0
    var screenshot = 0
    var cinematic = 0
    var slomo = 0
    var timelapse = 0
    var spatialVideo = 0
    var proraw = 0
    var hasPairedVideo = 0
}
