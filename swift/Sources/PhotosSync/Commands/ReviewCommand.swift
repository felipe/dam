import PhotosSyncLib
import ArgumentParser
import Foundation
import Photos

struct ReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Review and manage problem assets (failed/skipped imports)"
    )
    
    @Flag(name: .long, help: "Show only failed assets")
    var failedOnly: Bool = false
    
    @Flag(name: .long, help: "Show only skipped assets")
    var skippedOnly: Bool = false
    
    @Option(name: .long, help: "Export problem assets to JSON file")
    var export: String?
    
    @Flag(name: .long, help: "Retry importing failed assets")
    var retry: Bool = false
    
    @Option(name: .long, help: "Maximum number of assets to retry (0 = unlimited)")
    var limit: Int = 0
    
    @Flag(name: .long, help: "Preview what would be retried without making changes")
    var dryRun: Bool = false
    
    @Flag(name: .long, help: "Include photos that need to be downloaded from iCloud")
    var includeCloud: Bool = false
    
    @Option(name: .long, help: "Delay between iCloud downloads in seconds")
    var delay: Double = 5.0
    
    @Flag(name: .long, help: "Delete problem assets from Photos (moves to Recently Deleted)")
    var delete: Bool = false
    
    func run() async throws {
        guard let config = Config.load(dryRun: dryRun) else {
            throw ExitCode.failure
        }
        
        let tracker = try Tracker(dbPath: config.trackerDBPath)
        
        // Get problem assets based on filters
        let problems: [Tracker.ProblemAsset]
        if failedOnly {
            problems = tracker.getFailedAssets()
        } else if skippedOnly {
            problems = tracker.getSkippedAssets()
        } else {
            problems = tracker.getProblemAssets()
        }
        
        // Handle export mode
        if let exportPath = export {
            try exportProblems(problems, to: exportPath)
            return
        }
        
        // Handle delete mode
        if delete {
            try await deleteProblems(problems: problems, tracker: tracker)
            return
        }
        
        // Handle retry mode
        if retry {
            try await retryFailedAssets(problems: problems, config: config, tracker: tracker)
            return
        }
        
        // Default: display problem assets
        displayProblems(problems)
    }
    
    // MARK: - Display Mode
    
    private func displayProblems(_ problems: [Tracker.ProblemAsset]) {
        let stats = (
            failed: problems.filter { $0.status == "failed" }.count,
            skipped: problems.filter { $0.status == "skipped" }.count
        )
        
        print()
        print(String(repeating: "=", count: 60))
        print("PROBLEM ASSETS")
        print(String(repeating: "=", count: 60))
        print()
        print("Summary:")
        print("  Failed:  \(formatNumber(stats.failed))")
        print("  Skipped: \(formatNumber(stats.skipped))")
        print("  Total:   \(formatNumber(problems.count))")
        print()
        
        if problems.isEmpty {
            print("No problem assets found.")
            return
        }
        
        // Group by reason
        var byReason: [String: [Tracker.ProblemAsset]] = [:]
        for problem in problems {
            let reason = problem.reason.isEmpty ? "Unknown reason" : problem.reason
            byReason[reason, default: []].append(problem)
        }
        
        print("By Reason:")
        for (reason, assets) in byReason.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(reason): \(formatNumber(assets.count))")
        }
        print()
        
        // Show recent problems (last 20)
        let recent = Array(problems.prefix(20))
        print("Recent Problems (showing \(recent.count) of \(problems.count)):")
        print(String(repeating: "-", count: 60))
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        for problem in recent {
            let statusIcon = problem.status == "failed" ? "x" : "-"
            let dateStr: String
            if let createdAt = problem.createdAt {
                dateStr = dateFormatter.string(from: createdAt)
            } else {
                dateStr = "unknown date"
            }
            
            print("[\(statusIcon)] \(problem.filename)")
            print("    Type: \(problem.mediaType) | Date: \(dateStr)")
            print("    Reason: \(problem.reason)")
            print("    UUID: \(problem.uuid)")
            print()
        }
        
        if problems.count > 20 {
            print("... and \(problems.count - 20) more")
            print()
        }
        
        print("Actions:")
        print("  photos-sync review --export problems.json  # Export full list")
        print("  photos-sync review --retry                 # Retry failed imports")
        print("  photos-sync review --delete                # Delete from Photos")
        print("  photos-sync review --failed-only           # Show only failures")
    }
    
    // MARK: - Delete Mode
    
    private func deleteProblems(
        problems: [Tracker.ProblemAsset],
        tracker: Tracker
    ) async throws {
        if problems.isEmpty {
            print("No problem assets to delete.")
            return
        }
        
        print("Requesting Photos access...")
        guard await PhotosFetcher.requestAccess() else {
            print("ERROR: Photos access denied. Grant access in System Settings -> Privacy -> Photos")
            throw ExitCode.failure
        }
        
        // Apply limit
        var toDelete = problems
        if limit > 0 && toDelete.count > limit {
            toDelete = Array(toDelete.prefix(limit))
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("DELETING \(formatNumber(toDelete.count)) PROBLEM ASSETS")
        print(String(repeating: "=", count: 50))
        print()
        
        if dryRun {
            print("DRY RUN MODE - No changes will be made")
            print()
            for (index, problem) in toDelete.enumerated() {
                print("[\(index + 1)/\(toDelete.count)] Would delete: \(problem.filename)")
                print("    Reason: \(problem.reason)")
            }
            print()
            print("DRY RUN - \(toDelete.count) asset(s) would be deleted")
            return
        }
        
        var deleted = 0
        var failed = 0
        var notFound = 0
        
        for (index, problem) in toDelete.enumerated() {
            let num = index + 1
            print("[\(num)/\(toDelete.count)] \(problem.filename)")
            
            let result = await PhotosDeleter.deleteAsset(identifier: problem.uuid)
            
            if result.success {
                print("  Deleted (moved to Recently Deleted)")
                // Remove from tracker
                try? tracker.clearProblemStatus(uuid: problem.uuid)
                deleted += 1
            } else if result.error == "Asset not found" {
                print("  Not found in Photos (already deleted?)")
                // Still remove from tracker
                try? tracker.clearProblemStatus(uuid: problem.uuid)
                notFound += 1
            } else {
                print("  ERROR: \(result.error ?? "Unknown error")")
                failed += 1
            }
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("DELETE COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Deleted:   \(formatNumber(deleted))")
        if notFound > 0 {
            print("Not found: \(formatNumber(notFound))")
        }
        if failed > 0 {
            print("Failed:    \(formatNumber(failed))")
        }
    }
    
    // MARK: - Export Mode
    
    private func exportProblems(_ problems: [Tracker.ProblemAsset], to path: String) throws {
        let stats = (
            failed: problems.filter { $0.status == "failed" }.count,
            skipped: problems.filter { $0.status == "skipped" }.count
        )
        
        let dateFormatter = ISO8601DateFormatter()
        
        // Build JSON structure
        var assetsArray: [[String: Any]] = []
        for problem in problems {
            var asset: [String: Any] = [
                "uuid": problem.uuid,
                "filename": problem.filename,
                "media_type": problem.mediaType,
                "status": problem.status,
                "reason": problem.reason,
                "recorded_at": dateFormatter.string(from: problem.recordedAt)
            ]
            if let createdAt = problem.createdAt {
                asset["asset_created_at"] = dateFormatter.string(from: createdAt)
            }
            assetsArray.append(asset)
        }
        
        let exportData: [String: Any] = [
            "exported_at": dateFormatter.string(from: Date()),
            "summary": [
                "total": problems.count,
                "failed": stats.failed,
                "skipped": stats.skipped
            ],
            "assets": assetsArray
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
        
        let fileURL = URL(fileURLWithPath: path)
        try jsonData.write(to: fileURL)
        
        print("Exported \(problems.count) problem assets to: \(path)")
        print("  Failed:  \(stats.failed)")
        print("  Skipped: \(stats.skipped)")
    }
    
    // MARK: - Retry Mode
    
    private func retryFailedAssets(
        problems: [Tracker.ProblemAsset],
        config: Config,
        tracker: Tracker
    ) async throws {
        // Only retry failed assets, not skipped
        let failedAssets = problems.filter { $0.status == "failed" }
        
        if failedAssets.isEmpty {
            print("No failed assets to retry.")
            return
        }
        
        print("Requesting Photos access...")
        guard await PhotosFetcher.requestAccess() else {
            print("ERROR: Photos access denied. Grant access in System Settings -> Privacy -> Photos")
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
        
        // Get all Photos library assets to cross-reference
        print("Loading Photos library...")
        let allAssets = PhotosFetcher.getAllAssets()
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        
        // Filter to assets still in library
        var toRetry: [(problem: Tracker.ProblemAsset, asset: PhotosFetcher.AssetInfo)] = []
        var notInLibrary = 0
        
        for problem in failedAssets {
            if let asset = assetMap[problem.uuid] {
                toRetry.append((problem, asset))
            } else {
                notInLibrary += 1
            }
        }
        
        if notInLibrary > 0 {
            print("Note: \(notInLibrary) failed assets no longer in Photos library")
        }
        
        // Apply limit
        if limit > 0 && toRetry.count > limit {
            toRetry = Array(toRetry.prefix(limit))
        }
        
        print("Assets to retry: \(formatNumber(toRetry.count))")
        
        if toRetry.isEmpty {
            print("Nothing to retry.")
            return
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("RETRYING \(formatNumber(toRetry.count)) FAILED ASSETS")
        print(String(repeating: "=", count: 50))
        print()
        
        var succeeded = 0
        var stillFailed = 0
        var skipped = 0
        
        for (index, item) in toRetry.enumerated() {
            let num = index + 1
            print("[\(num)/\(toRetry.count)] \(item.problem.filename)")
            print("  Previous failure: \(item.problem.reason)")
            
            if dryRun {
                print("  DRY RUN: Would retry import")
                skipped += 1
                continue
            }
            
            // Clear the problem status before retry
            try? tracker.clearProblemStatus(uuid: item.problem.uuid)
            
            // Attempt import
            let result = await retryImportAsset(
                asset: item.asset,
                config: config,
                immich: immich,
                tracker: tracker,
                allowNetwork: includeCloud
            )
            
            if result.success {
                print("  SUCCESS: Imported to Immich")
                succeeded += 1
            } else {
                print("  FAILED: \(result.error ?? "Unknown error")")
                stillFailed += 1
            }
            
            // Delay between retries
            if index < toRetry.count - 1 && delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // Summary
        print()
        print(String(repeating: "=", count: 50))
        print("RETRY COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Succeeded:    \(formatNumber(succeeded))")
        print("Still failed: \(formatNumber(stillFailed))")
        if dryRun {
            print("Skipped:      \(formatNumber(skipped)) (dry run)")
        }
    }
    
    private func retryImportAsset(
        asset: PhotosFetcher.AssetInfo,
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        allowNetwork: Bool
    ) async -> (success: Bool, error: String?) {
        // Get dates
        let dates = PhotosFetcher.getAssetDates(identifier: asset.localIdentifier)
        
        // Handle Cinematic videos
        if asset.isCinematic {
            return await retryCinematicVideo(
                asset: asset,
                dates: dates,
                config: config,
                immich: immich,
                tracker: tracker,
                allowNetwork: allowNetwork
            )
        }
        
        // Handle assets with paired video
        if asset.hasPairedVideo {
            return await retryPairedAsset(
                asset: asset,
                dates: dates,
                config: config,
                immich: immich,
                tracker: tracker,
                allowNetwork: allowNetwork
            )
        }
        
        // Standard asset
        let downloadResult = await PhotosFetcher.downloadAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )
        
        if !downloadResult.success {
            let reason = downloadResult.error ?? "Download failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: mediaTypeString(asset.mediaType),
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
        guard let fileURL = downloadResult.fileURL else {
            let reason = "No file URL returned"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: mediaTypeString(asset.mediaType),
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
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
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: uploadResult.assetID,
                filename: downloadResult.filename,
                fileSize: downloadResult.fileSize,
                mediaType: downloadResult.mediaType,
                subtypes: subtypes,
                motionVideoImmichID: nil
            )
            return (true, nil)
        } else {
            let reason = uploadResult.error ?? "Upload failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: downloadResult.filename,
                mediaType: downloadResult.mediaType,
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
    }
    
    private func retryPairedAsset(
        asset: PhotosFetcher.AssetInfo,
        dates: (created: Date?, modified: Date?),
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        allowNetwork: Bool
    ) async -> (success: Bool, error: String?) {
        let livePhotoResult = await PhotosFetcher.downloadPairedAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )
        
        if !livePhotoResult.success {
            let reason = livePhotoResult.imageResult.error ?? "Image export failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: mediaTypeString(asset.mediaType),
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
        guard let imageURL = livePhotoResult.imageResult.fileURL else {
            let reason = "No image file URL returned"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: mediaTypeString(asset.mediaType),
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
        var motionVideoImmichID: String? = nil
        
        // Upload video first if available
        if livePhotoResult.hasVideo, let videoResult = livePhotoResult.videoResult, let videoURL = videoResult.fileURL {
            let videoDeviceID = "\(asset.localIdentifier)_video"
            let videoUploadResult = await immich.uploadAsset(
                fileURL: videoURL,
                deviceAssetID: videoDeviceID,
                fileCreatedAt: dates.created,
                fileModifiedAt: dates.modified
            )
            
            try? FileManager.default.removeItem(at: videoURL)
            
            if videoUploadResult.success {
                motionVideoImmichID = videoUploadResult.assetID
            }
        }
        
        // Upload image linked to video
        let imageUploadResult = await immich.uploadAsset(
            fileURL: imageURL,
            deviceAssetID: asset.localIdentifier,
            fileCreatedAt: dates.created,
            fileModifiedAt: dates.modified,
            livePhotoVideoId: motionVideoImmichID
        )
        
        try? FileManager.default.removeItem(at: imageURL)
        
        if imageUploadResult.success {
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
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: imageUploadResult.assetID,
                filename: livePhotoResult.imageResult.filename,
                fileSize: livePhotoResult.imageResult.fileSize,
                mediaType: livePhotoResult.imageResult.mediaType,
                subtypes: subtypes,
                motionVideoImmichID: motionVideoImmichID
            )
            return (true, nil)
        } else {
            let reason = imageUploadResult.error ?? "Image upload failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: livePhotoResult.imageResult.filename,
                mediaType: livePhotoResult.imageResult.mediaType,
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
    }
    
    private func retryCinematicVideo(
        asset: PhotosFetcher.AssetInfo,
        dates: (created: Date?, modified: Date?),
        config: Config,
        immich: ImmichClient,
        tracker: Tracker,
        allowNetwork: Bool
    ) async -> (success: Bool, error: String?) {
        let cinematicResult = await PhotosFetcher.downloadCinematicVideoAsset(
            identifier: asset.localIdentifier,
            to: config.stagingDir,
            allowNetwork: allowNetwork
        )
        
        if !cinematicResult.success {
            let reason = cinematicResult.videoResult.error ?? "Video export failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: "video",
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
        guard let videoURL = cinematicResult.videoResult.fileURL else {
            let reason = "No video file URL returned"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: asset.filename,
                mediaType: "video",
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
        
        // Move sidecars to permanent storage
        let assetSidecarDir = config.sidecarDir.appendingPathComponent(
            asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        )
        try? FileManager.default.createDirectory(at: assetSidecarDir, withIntermediateDirectories: true)
        
        var sidecarFilenames: [String] = []
        for sidecarURL in cinematicResult.sidecarURLs {
            let destURL = assetSidecarDir.appendingPathComponent(sidecarURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            if let _ = try? FileManager.default.moveItem(at: sidecarURL, to: destURL) {
                sidecarFilenames.append(destURL.lastPathComponent)
            }
        }
        
        // Upload video
        let uploadResult = await immich.uploadAsset(
            fileURL: videoURL,
            deviceAssetID: asset.localIdentifier,
            fileCreatedAt: dates.created,
            fileModifiedAt: dates.modified
        )
        
        try? FileManager.default.removeItem(at: videoURL)
        
        if uploadResult.success {
            let subtypes = Tracker.AssetSubtypes(
                isLivePhoto: asset.isLivePhoto,
                isPortrait: asset.isPortrait,
                isHDR: asset.isHDR,
                isPanorama: asset.isPanorama,
                isScreenshot: asset.isScreenshot,
                isCinematic: true,
                isSlomo: asset.isSlomo,
                isTimelapse: asset.isTimelapse,
                isSpatialVideo: asset.isSpatialVideo,
                isProRAW: asset.isProRAW,
                hasPairedVideo: asset.hasPairedVideo
            )
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: uploadResult.assetID,
                filename: cinematicResult.videoResult.filename,
                fileSize: cinematicResult.videoResult.fileSize,
                mediaType: cinematicResult.videoResult.mediaType,
                subtypes: subtypes,
                motionVideoImmichID: nil,
                cinematicSidecars: sidecarFilenames.isEmpty ? nil : sidecarFilenames
            )
            return (true, nil)
        } else {
            let reason = uploadResult.error ?? "Video upload failed"
            try? tracker.markFailed(
                uuid: asset.localIdentifier,
                filename: cinematicResult.videoResult.filename,
                mediaType: "video",
                reason: reason,
                createdAt: asset.creationDate
            )
            return (false, reason)
        }
    }
    
    // MARK: - Helpers
    
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    
    private func mediaTypeString(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
}
