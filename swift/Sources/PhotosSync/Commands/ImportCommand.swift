import PhotosSyncLib
import ArgumentParser
import Foundation
import Photos

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import photos from Photos.app to Immich"
    )
    
    @Flag(name: .long, help: "Preview what would be imported without making changes")
    var dryRun: Bool = false
    
    @Flag(name: .long, help: "Include photos that need to be downloaded from iCloud")
    var includeCloud: Bool = false
    
    @Flag(name: .long, help: "Skip slow local availability check, fail fast on cloud-only assets")
    var skipLocalCheck: Bool = false
    
    @Option(name: .long, help: "Maximum number of photos to process (0 = unlimited)")
    var limit: Int = 0
    
    @Option(name: .long, help: "Number of concurrent imports")
    var concurrency: Int = 1
    
    @Option(name: .long, help: "Delay between iCloud downloads in seconds")
    var delay: Double = 5.0
    
    @Flag(name: .long, help: "Repair Live Photos that were imported without motion video")
    var repairLivePhotos: Bool = false

    @Flag(name: .long, help: "Repair Cinematic videos that were imported without sidecars")
    var repairCinematic: Bool = false

    func run() async throws {
        // Handle repair mode separately
        if repairLivePhotos {
            try await runRepairMode()
            return
        }
        if repairCinematic {
            try await runCinematicRepairMode()
            return
        }
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
        print("Already imported: \(formatNumber(importedUUIDs.count))")
        
        // Get assets
        print("Loading Photos library...")
        let allAssets = PhotosFetcher.getAllAssets()
        print("Total assets in library: \(formatNumber(allAssets.count))")
        
        // Filter to not-yet-imported
        let candidates = allAssets.filter { !importedUUIDs.contains($0.localIdentifier) }
        print("Not yet imported: \(formatNumber(candidates.count))")
        
        // Filter by local/cloud if needed
        var toImport: [PhotosFetcher.AssetInfo] = []
        if includeCloud || skipLocalCheck {
            // Skip the slow local check - just import everything
            // With skipLocalCheck, cloud-only assets will fail fast during download
            if skipLocalCheck && !includeCloud {
                print("Skipping local availability check (will fail fast on cloud-only assets)")
            }
            toImport = candidates
            // Apply limit
            if limit > 0 && toImport.count > limit {
                toImport = Array(toImport.prefix(limit))
            }
        } else {
            print("Checking which assets are locally available...")
            var cloudSkipped = 0
            for (idx, asset) in candidates.enumerated() {
                if limit > 0 && toImport.count >= limit { break }
                
                if idx % 100 == 0 && idx > 0 {
                    print("  Checked \(idx)/\(candidates.count)...")
                }
                
                if PhotosFetcher.isAssetLocal(asset.localIdentifier) {
                    toImport.append(asset)
                } else {
                    cloudSkipped += 1
                    // Stop checking after finding enough or hitting too many cloud assets
                    if cloudSkipped > 1000 && toImport.count == 0 {
                        print("  Most assets are in iCloud, stopping local scan")
                        break
                    }
                }
            }
            if cloudSkipped > 0 {
                print("Skipping \(formatNumber(cloudSkipped)) assets in iCloud (use --include-cloud to download)")
            }
        }
        
        print("Assets to import: \(formatNumber(toImport.count))")
        
        if toImport.isEmpty {
            print("Nothing to import.")
            return
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("IMPORTING \(formatNumber(toImport.count)) ASSETS (concurrency: \(concurrency))")
        print(String(repeating: "=", count: 50))
        print()
        
        let stats = ImportStatsActor()
        let totalCount = toImport.count
        
        if concurrency <= 1 {
            // Sequential processing (original behavior)
            for (index, asset) in toImport.enumerated() {
                await processAsset(
                    asset: asset,
                    index: index,
                    total: totalCount,
                    config: config,
                    immich: immich,
                    tracker: tracker,
                    stats: stats,
                    dryRun: dryRun,
                    allowNetwork: includeCloud
                )
                
                // Delay between iCloud downloads
                if index < toImport.count - 1 && delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        } else {
            // Concurrent processing
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                var nextIndex = 0
                
                while nextIndex < toImport.count {
                    // Add tasks up to concurrency limit
                    while inFlight < concurrency && nextIndex < toImport.count {
                        let asset = toImport[nextIndex]
                        let index = nextIndex
                        nextIndex += 1
                        inFlight += 1
                        
                        group.addTask {
                            await self.processAsset(
                                asset: asset,
                                index: index,
                                total: totalCount,
                                config: config,
                                immich: immich,
                                tracker: tracker,
                                stats: stats,
                                dryRun: self.dryRun,
                                allowNetwork: self.includeCloud
                            )
                            
                            // Small delay per task to be gentle on iCloud
                            if self.delay > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
                            }
                        }
                    }
                    
                    // Wait for one to complete before adding more
                    await group.next()
                    inFlight -= 1
                }
                
                // Wait for remaining tasks
                for await _ in group {}
            }
        }
        
        // Summary
        let finalStats = await stats.getStats()
        print()
        print(String(repeating: "=", count: 50))
        print("IMPORT COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Exported:   \(formatNumber(finalStats.exported))")
        print("Uploaded:   \(formatNumber(finalStats.uploaded))")
        print("Duplicates: \(formatNumber(finalStats.duplicates))")
        print("Failed:     \(formatNumber(finalStats.failed))")
        if finalStats.livePhotos > 0 {
            print("Live Photos: \(formatNumber(finalStats.livePhotos)) (with \(formatNumber(finalStats.livePhotoVideos)) videos)")
        }
        if finalStats.cinematicVideos > 0 {
            print("Cinematic:  \(formatNumber(finalStats.cinematicVideos)) (with \(formatNumber(finalStats.cinematicSidecars)) sidecars)")
        }
        if dryRun {
            print("Skipped:    \(formatNumber(finalStats.skipped)) (dry run)")
        }
        
        let trackerStats = tracker.getStats()
        print()
        print("Total in Immich: \(formatNumber(trackerStats.total)) (\(formatBytes(trackerStats.totalBytes)))")
    }
    
    /// Repair mode: Find Live Photos imported without motion video and re-upload them properly
    private func runRepairMode() async throws {
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
        
        // Get stats on Live Photos
        let livePhotoStats = tracker.getLivePhotoStats()
        print()
        print("Live Photo Status:")
        print("  Total tracked:     \(formatNumber(livePhotoStats.total))")
        print("  With motion video: \(formatNumber(livePhotoStats.withMotionVideo))")
        print("  Needing repair:    \(formatNumber(livePhotoStats.needingRepair))")
        print()
        
        // Get Live Photos needing repair
        let needingRepair = tracker.getLivePhotosNeedingRepair()
        
        if needingRepair.isEmpty {
            print("No Live Photos need repair.")
            return
        }
        
        // Get all Photos library assets to cross-reference
        print("Loading Photos library to find Live Photos...")
        let allAssets = PhotosFetcher.getAllAssets()
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        
        // Filter to only those that are actually Live Photos in the library
        var toRepair: [(info: Tracker.LivePhotoRepairInfo, asset: PhotosFetcher.AssetInfo)] = []
        for info in needingRepair {
            guard let asset = assetMap[info.uuid] else {
                // Asset no longer in library, skip
                continue
            }
            
            if asset.isLivePhoto {
                toRepair.append((info, asset))
            } else {
                // Not actually a Live Photo - update tracker to mark as non-Live Photo
                if !dryRun {
                    try? tracker.updateLivePhotoInfo(uuid: info.uuid, isLivePhoto: false, motionVideoImmichID: nil)
                }
            }
        }
        
        // Apply limit
        if limit > 0 && toRepair.count > limit {
            toRepair = Array(toRepair.prefix(limit))
        }
        
        print("Live Photos to repair: \(formatNumber(toRepair.count))")
        
        if toRepair.isEmpty {
            print("No Live Photos need repair after verification.")
            return
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("REPAIRING \(formatNumber(toRepair.count)) LIVE PHOTOS")
        print(String(repeating: "=", count: 50))
        print()
        
        var repaired = 0
        var failed = 0
        var skipped = 0
        
        for (index, item) in toRepair.enumerated() {
            let num = index + 1
            print("[\(num)/\(toRepair.count)] \(item.info.filename)")
            
            if dryRun {
                print("  DRY RUN: Would repair Live Photo")
                skipped += 1
                continue
            }
            
            // Check if asset has paired video resource
            guard PhotosFetcher.hasPairedVideoResource(identifier: item.info.uuid) else {
                print("  WARNING: No paired video in Photos library")
                // Mark as non-Live Photo to prevent future repair attempts
                try? tracker.updateLivePhotoInfo(uuid: item.info.uuid, isLivePhoto: false, motionVideoImmichID: nil)
                skipped += 1
                continue
            }
            
            // Download just the video component
            print("  Exporting motion video...")
            let videoResult = await downloadPairedVideoOnly(
                identifier: item.info.uuid,
                to: config.stagingDir,
                allowNetwork: includeCloud
            )
            
            guard videoResult.success, let videoURL = videoResult.fileURL else {
                print("  ERROR: \(videoResult.error ?? "Video export failed")")
                failed += 1
                continue
            }
            
            print("  Video exported: \(formatBytes(videoResult.fileSize))")
            
            // Get dates
            let dates = PhotosFetcher.getAssetDates(identifier: item.info.uuid)
            
            // Upload video
            let videoDeviceID = "\(item.info.uuid)_video"
            let videoUploadResult = await immich.uploadAsset(
                fileURL: videoURL,
                deviceAssetID: videoDeviceID,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified
            )
            
            // Clean up video staging file
            try? FileManager.default.removeItem(at: videoURL)
            
            guard videoUploadResult.success, let videoImmichID = videoUploadResult.assetID else {
                print("  ERROR: Video upload failed: \(videoUploadResult.error ?? "unknown")")
                failed += 1
                continue
            }
            
            if videoUploadResult.duplicate {
                print("  Video: duplicate in Immich")
            } else {
                print("  Video uploaded: \(videoImmichID)")
            }
            
            // Now we need to re-upload the image linked to the video
            // First, delete the old image from Immich (if it exists)
            if let oldImmichID = item.info.immichID {
                print("  Deleting old image asset from Immich...")
                let deleteResult = await immich.deleteAssets(ids: [oldImmichID], force: true)
                if deleteResult.success {
                    print("  Deleted old asset: \(oldImmichID)")
                } else {
                    print("  WARNING: Could not delete old asset: \(deleteResult.error ?? "unknown")")
                    // Continue anyway - we'll upload a new linked version
                }
            }
            
            // Export and upload the image again, this time linked to the video
            print("  Exporting image...")
            let imageResult = await PhotosFetcher.downloadAsset(
                identifier: item.info.uuid,
                to: config.stagingDir,
                allowNetwork: includeCloud
            )
            
            guard imageResult.success, let imageURL = imageResult.fileURL else {
                print("  ERROR: Image export failed: \(imageResult.error ?? "unknown")")
                failed += 1
                continue
            }
            
            print("  Image exported: \(formatBytes(imageResult.fileSize))")
            
            // Upload image linked to video
            let imageUploadResult = await immich.uploadAsset(
                fileURL: imageURL,
                deviceAssetID: item.info.uuid,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified,
                livePhotoVideoId: videoImmichID
            )
            
            // Clean up image staging file
            try? FileManager.default.removeItem(at: imageURL)
            
            if imageUploadResult.success {
                print("  Image uploaded: \(imageUploadResult.assetID ?? "unknown") (linked to video)")
                
                // Update tracker with the new info
                try? tracker.markImported(
                    uuid: item.info.uuid,
                    immichID: imageUploadResult.assetID,
                    filename: imageResult.filename,
                    fileSize: imageResult.fileSize,
                    mediaType: imageResult.mediaType,
                    isLivePhoto: true,
                    motionVideoImmichID: videoImmichID
                )
                repaired += 1
            } else {
                print("  ERROR: Image upload failed: \(imageUploadResult.error ?? "unknown")")
                failed += 1
            }
            
            // Delay between repairs
            if index < toRepair.count - 1 && delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // Summary
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
    
    /// Download just the paired video component of a Live Photo (wrapper for repair mode)
    private func downloadPairedVideoOnly(
        identifier: String,
        to stagingDir: URL,
        allowNetwork: Bool
    ) async -> PhotosFetcher.DownloadResult {
        // We need to access the private downloadPairedVideo function
        // Since it's private in PhotosFetcher, we'll use downloadLivePhotoAsset and extract just the video
        let result = await PhotosFetcher.downloadLivePhotoAsset(
            identifier: identifier,
            to: stagingDir,
            allowNetwork: allowNetwork
        )
        
        // Clean up the image file if it was exported
        if let imageURL = result.imageResult.fileURL {
            try? FileManager.default.removeItem(at: imageURL)
        }
        
        // Return the video result
        if let videoResult = result.videoResult {
            return videoResult
        } else {
            return PhotosFetcher.DownloadResult(
                localIdentifier: identifier,
                filename: "unknown",
                fileURL: nil,
                fileSize: 0,
                mediaType: "video",
                error: "No paired video found"
            )
        }
    }
    
    private func processAsset(
        asset: PhotosFetcher.AssetInfo,
        index: Int,
        total: Int,
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        stats: ImportStatsActor,
        dryRun: Bool,
        allowNetwork: Bool
    ) async {
        let num = index + 1
        var label = ""
        if asset.isLivePhoto { label = " [Live]" }
        else if asset.isCinematic { label = " [Cinematic]" }
        print("[\(num)/\(total)] \(asset.filename)\(label)")

        if dryRun {
            print("  DRY RUN: Would download and upload")
            await stats.incrementSkipped()
            return
        }

        // Get dates upfront
        let dates = PhotosFetcher.getAssetDates(identifier: asset.localIdentifier)

        // Handle Live Photos with two-step upload
        if asset.isLivePhoto {
            await processLivePhoto(
                asset: asset,
                dates: dates,
                config: config,
                immich: immich,
                tracker: tracker,
                stats: stats,
                allowNetwork: allowNetwork
            )
            return
        }

        // Handle Cinematic videos with multi-resource export
        if asset.isCinematic {
            await processCinematicVideo(
                asset: asset,
                dates: dates,
                config: config,
                immich: immich,
                tracker: tracker,
                stats: stats,
                allowNetwork: allowNetwork
            )
            return
        }

        // Standard asset processing (non-Live Photo, non-Cinematic)
        if allowNetwork {
            print("  Downloading from iCloud...")
        } else {
            print("  Exporting...")
        }
        
        let downloadResult = await PhotosFetcher.downloadAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )
        
        if !downloadResult.success {
            print("  ERROR: \(downloadResult.error ?? "Download failed")")
            await stats.incrementFailed()
            return
        }
        
        guard let fileURL = downloadResult.fileURL else {
            print("  ERROR: No file URL")
            await stats.incrementFailed()
            return
        }
        
        await stats.incrementExported()
        print("  Exported: \(formatBytes(downloadResult.fileSize))")
        
        // Upload to Immich
        let uploadResult = await immich.uploadAsset(
            fileURL: fileURL,
            deviceAssetID: asset.localIdentifier,
            fileCreatedAt: dates.created,
            fileModifiedAt: dates.modified
        )
        
        // Clean up staging file
        try? FileManager.default.removeItem(at: fileURL)
        
        if uploadResult.success {
            if uploadResult.duplicate {
                print("  Duplicate in Immich")
                await stats.incrementDuplicates()
            } else {
                print("  Uploaded: \(uploadResult.assetID ?? "unknown")")
                await stats.incrementUploaded()
            }
            
            // Track as imported (not a Live Photo)
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: uploadResult.assetID,
                filename: downloadResult.filename,
                fileSize: downloadResult.fileSize,
                mediaType: downloadResult.mediaType,
                isLivePhoto: false,
                motionVideoImmichID: nil
            )
        } else {
            print("  ERROR: \(uploadResult.error ?? "Upload failed")")
            await stats.incrementFailed()
        }
    }
    
    /// Process a Live Photo - uploads video first, then image linked to video
    private func processLivePhoto(
        asset: PhotosFetcher.AssetInfo,
        dates: (created: Date?, modified: Date?),
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        stats: ImportStatsActor,
        allowNetwork: Bool
    ) async {
        print("  Exporting Live Photo (image + video)...")
        
        // Download both image and video
        let livePhotoResult = await PhotosFetcher.downloadLivePhotoAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )
        
        // Check if image export succeeded
        if !livePhotoResult.success {
            print("  ERROR: \(livePhotoResult.imageResult.error ?? "Image export failed")")
            await stats.incrementFailed()
            return
        }
        
        guard let imageURL = livePhotoResult.imageResult.fileURL else {
            print("  ERROR: No image file URL")
            await stats.incrementFailed()
            return
        }
        
        await stats.incrementExported()
        print("  Image exported: \(formatBytes(livePhotoResult.imageResult.fileSize))")
        
        var motionVideoImmichID: String? = nil
        
        // Step 1: Upload the motion video first (if available)
        if livePhotoResult.hasVideo, let videoResult = livePhotoResult.videoResult, let videoURL = videoResult.fileURL {
            print("  Video exported: \(formatBytes(videoResult.fileSize))")
            
            // Upload video with special device asset ID
            let videoDeviceID = "\(asset.localIdentifier)_video"
            let videoUploadResult = await immich.uploadAsset(
                fileURL: videoURL,
                deviceAssetID: videoDeviceID,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified
            )
            
            // Clean up video staging file
            try? FileManager.default.removeItem(at: videoURL)
            
            if videoUploadResult.success {
                motionVideoImmichID = videoUploadResult.assetID
                if videoUploadResult.duplicate {
                    print("  Video: duplicate in Immich")
                } else {
                    print("  Video uploaded: \(videoUploadResult.assetID ?? "unknown")")
                }
                await stats.incrementLivePhotoVideos()
            } else {
                // Video upload failed, but we can still upload image without link
                print("  WARNING: Video upload failed: \(videoUploadResult.error ?? "unknown")")
            }
        } else {
            // No video available
            if let videoResult = livePhotoResult.videoResult {
                print("  WARNING: Video export failed: \(videoResult.error ?? "unknown")")
            } else {
                print("  WARNING: No paired video found")
            }
        }
        
        // Step 2: Upload the image, linked to video if available
        let imageUploadResult = await immich.uploadAsset(
            fileURL: imageURL,
            deviceAssetID: asset.localIdentifier,
            fileCreatedAt: dates.created,
            fileModifiedAt: dates.modified,
            livePhotoVideoId: motionVideoImmichID
        )
        
        // Clean up image staging file
        try? FileManager.default.removeItem(at: imageURL)
        
        if imageUploadResult.success {
            if imageUploadResult.duplicate {
                print("  Image: duplicate in Immich")
                await stats.incrementDuplicates()
            } else {
                let linkStatus = motionVideoImmichID != nil ? " (linked to video)" : " (no video link)"
                print("  Image uploaded: \(imageUploadResult.assetID ?? "unknown")\(linkStatus)")
                await stats.incrementUploaded()
                await stats.incrementLivePhotos()
            }
            
            // Track as imported Live Photo
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: imageUploadResult.assetID,
                filename: livePhotoResult.imageResult.filename,
                fileSize: livePhotoResult.imageResult.fileSize,
                mediaType: livePhotoResult.imageResult.mediaType,
                isLivePhoto: true,
                motionVideoImmichID: motionVideoImmichID
            )
        } else {
            print("  ERROR: Image upload failed: \(imageUploadResult.error ?? "unknown")")
            await stats.incrementFailed()
        }
    }

    /// Process a Cinematic video - uploads main video and preserves sidecars
    private func processCinematicVideo(
        asset: PhotosFetcher.AssetInfo,
        dates: (created: Date?, modified: Date?),
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        stats: ImportStatsActor,
        allowNetwork: Bool
    ) async {
        print("  Exporting Cinematic video (video + sidecars)...")

        // Download all resources (main video + sidecars)
        let cinematicResult = await PhotosFetcher.downloadCinematicVideoAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )

        // Check if main video export succeeded
        if !cinematicResult.success {
            print("  ERROR: \(cinematicResult.videoResult.error ?? "Video export failed")")
            await stats.incrementFailed()
            return
        }

        guard let videoURL = cinematicResult.videoResult.fileURL else {
            print("  ERROR: No video file URL")
            await stats.incrementFailed()
            return
        }

        await stats.incrementExported()
        print("  Video exported: \(formatBytes(cinematicResult.videoResult.fileSize))")

        // Report sidecar status
        var sidecarFilenames: [String] = []
        if cinematicResult.hasAdjustmentData, let aaeResult = cinematicResult.adjustmentDataResult {
            print("  AAE sidecar: \(formatBytes(aaeResult.fileSize))")
        }
        if cinematicResult.hasBaseVideo, let baseResult = cinematicResult.baseVideoResult {
            print("  Base video: \(formatBytes(baseResult.fileSize))")
        }
        if cinematicResult.hasRenderedVideo, let renderedResult = cinematicResult.renderedVideoResult {
            print("  Rendered video: \(formatBytes(renderedResult.fileSize))")
        }

        // Move sidecars to permanent storage (sidecar directory)
        // Create subdirectory for this asset's sidecars
        let assetSidecarDir = config.sidecarDir.appendingPathComponent(
            asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        )
        try? FileManager.default.createDirectory(at: assetSidecarDir, withIntermediateDirectories: true)

        for sidecarURL in cinematicResult.sidecarURLs {
            let destURL = assetSidecarDir.appendingPathComponent(sidecarURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.moveItem(at: sidecarURL, to: destURL)
                sidecarFilenames.append(destURL.lastPathComponent)
                await stats.incrementCinematicSidecars()
            } catch {
                print("  WARNING: Could not move sidecar \(sidecarURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !sidecarFilenames.isEmpty {
            print("  Sidecars saved to: \(assetSidecarDir.path)")
        }

        // Upload main video to Immich
        let uploadResult = await immich.uploadAsset(
            fileURL: videoURL,
            deviceAssetID: asset.localIdentifier,
            fileCreatedAt: dates.created,
            fileModifiedAt: dates.modified
        )

        // Clean up staging file
        try? FileManager.default.removeItem(at: videoURL)

        if uploadResult.success {
            if uploadResult.duplicate {
                print("  Video: duplicate in Immich")
                await stats.incrementDuplicates()
            } else {
                print("  Video uploaded: \(uploadResult.assetID ?? "unknown")")
                await stats.incrementUploaded()
                await stats.incrementCinematicVideos()
            }

            // Track as imported Cinematic video
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: uploadResult.assetID,
                filename: cinematicResult.videoResult.filename,
                fileSize: cinematicResult.videoResult.fileSize,
                mediaType: cinematicResult.videoResult.mediaType,
                isLivePhoto: false,
                motionVideoImmichID: nil,
                isCinematic: true,
                cinematicSidecars: sidecarFilenames.isEmpty ? nil : sidecarFilenames
            )
        } else {
            print("  ERROR: Video upload failed: \(uploadResult.error ?? "unknown")")
            await stats.incrementFailed()
        }
    }

    /// Repair mode: Find Cinematic videos imported without sidecars and re-export sidecars
    private func runCinematicRepairMode() async throws {
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

        // Get stats on Cinematic videos
        let cinematicStats = tracker.getCinematicStats()
        print()
        print("Cinematic Video Status:")
        print("  Total tracked:    \(formatNumber(cinematicStats.total))")
        print("  With sidecars:    \(formatNumber(cinematicStats.withSidecars))")
        print("  Needing repair:   \(formatNumber(cinematicStats.needingRepair))")
        print()

        // Get Cinematic videos needing repair
        let needingRepair = tracker.getCinematicsNeedingRepair()

        if needingRepair.isEmpty {
            print("No Cinematic videos need repair.")
            return
        }

        // Get all Photos library assets to cross-reference
        print("Loading Photos library to find Cinematic videos...")
        let allAssets = PhotosFetcher.getAllAssets()
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })

        // Filter to only those that are actually Cinematic in the library
        var toRepair: [(info: Tracker.CinematicRepairInfo, asset: PhotosFetcher.AssetInfo)] = []
        for info in needingRepair {
            guard let asset = assetMap[info.uuid] else {
                // Asset no longer in library, skip
                continue
            }

            if asset.isCinematic {
                toRepair.append((info, asset))
            } else {
                // Not actually Cinematic - update tracker
                if !dryRun {
                    try? tracker.updateCinematicInfo(uuid: info.uuid, isCinematic: false, sidecars: nil)
                }
            }
        }

        // Apply limit
        if limit > 0 && toRepair.count > limit {
            toRepair = Array(toRepair.prefix(limit))
        }

        print("Cinematic videos to repair: \(formatNumber(toRepair.count))")

        if toRepair.isEmpty {
            print("No Cinematic videos need repair after verification.")
            return
        }

        print()
        print(String(repeating: "=", count: 50))
        print("REPAIRING \(formatNumber(toRepair.count)) CINEMATIC VIDEOS")
        print(String(repeating: "=", count: 50))
        print()

        var repaired = 0
        var failed = 0
        var skipped = 0

        for (index, item) in toRepair.enumerated() {
            let num = index + 1
            print("[\(num)/\(toRepair.count)] \(item.info.filename)")

            if dryRun {
                print("  DRY RUN: Would repair Cinematic video sidecars")
                skipped += 1
                continue
            }

            // Download all resources (we only need the sidecars)
            print("  Exporting sidecars...")
            let cinematicResult = await PhotosFetcher.downloadCinematicVideoAsset(
                identifier: item.info.uuid,
                to: config.stagingDir,
                allowNetwork: includeCloud
            )

            // Clean up main video file - we don't need it for repair
            if let videoURL = cinematicResult.videoResult.fileURL {
                try? FileManager.default.removeItem(at: videoURL)
            }

            // Check if we got any sidecars
            if cinematicResult.sidecarURLs.isEmpty {
                print("  WARNING: No sidecars found for this Cinematic video")
                // Update tracker to mark as Cinematic with no sidecars
                try? tracker.updateCinematicInfo(uuid: item.info.uuid, isCinematic: true, sidecars: nil)
                skipped += 1
                continue
            }

            // Move sidecars to permanent storage
            let assetSidecarDir = config.sidecarDir.appendingPathComponent(
                item.info.uuid.replacingOccurrences(of: "/", with: "_")
            )
            try? FileManager.default.createDirectory(at: assetSidecarDir, withIntermediateDirectories: true)

            var sidecarFilenames: [String] = []
            for sidecarURL in cinematicResult.sidecarURLs {
                let destURL = assetSidecarDir.appendingPathComponent(sidecarURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.moveItem(at: sidecarURL, to: destURL)
                    sidecarFilenames.append(destURL.lastPathComponent)
                    print("  Saved: \(destURL.lastPathComponent)")
                } catch {
                    print("  WARNING: Could not move sidecar: \(error.localizedDescription)")
                }
            }

            if !sidecarFilenames.isEmpty {
                // Update tracker with sidecar info
                try? tracker.updateCinematicInfo(
                    uuid: item.info.uuid,
                    isCinematic: true,
                    sidecars: sidecarFilenames
                )
                print("  Sidecars saved to: \(assetSidecarDir.path)")
                repaired += 1
            } else {
                failed += 1
            }

            // Delay between repairs
            if index < toRepair.count - 1 && delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        // Summary
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

// Thread-safe stats using actor
actor ImportStatsActor {
    private var exported = 0
    private var uploaded = 0
    private var duplicates = 0
    private var failed = 0
    private var skipped = 0
    private var livePhotos = 0
    private var livePhotoVideos = 0
    private var cinematicVideos = 0
    private var cinematicSidecars = 0

    func incrementExported() { exported += 1 }
    func incrementUploaded() { uploaded += 1 }
    func incrementDuplicates() { duplicates += 1 }
    func incrementFailed() { failed += 1 }
    func incrementSkipped() { skipped += 1 }
    func incrementLivePhotos() { livePhotos += 1 }
    func incrementLivePhotoVideos() { livePhotoVideos += 1 }
    func incrementCinematicVideos() { cinematicVideos += 1 }
    func incrementCinematicSidecars() { cinematicSidecars += 1 }

    func getStats() -> (exported: Int, uploaded: Int, duplicates: Int, failed: Int, skipped: Int, livePhotos: Int, livePhotoVideos: Int, cinematicVideos: Int, cinematicSidecars: Int) {
        (exported, uploaded, duplicates, failed, skipped, livePhotos, livePhotoVideos, cinematicVideos, cinematicSidecars)
    }
}
