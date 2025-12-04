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
        if dryRun {
            print("Skipped:    \(formatNumber(finalStats.skipped)) (dry run)")
        }
        
        let trackerStats = tracker.getStats()
        print()
        print("Total in Immich: \(formatNumber(trackerStats.total)) (\(formatBytes(trackerStats.totalBytes)))")
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
        print("[\(num)/\(total)] \(asset.filename)")
        
        if dryRun {
            print("  DRY RUN: Would download and upload")
            await stats.incrementSkipped()
            return
        }
        
        // Export/download the asset
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
        
        // Get dates
        let dates = PhotosFetcher.getAssetDates(identifier: asset.localIdentifier)
        
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
            
            // Track as imported
            try? tracker.markImported(
                uuid: asset.localIdentifier,
                immichID: uploadResult.assetID,
                filename: downloadResult.filename,
                fileSize: downloadResult.fileSize,
                mediaType: downloadResult.mediaType
            )
        } else {
            print("  ERROR: \(uploadResult.error ?? "Upload failed")")
            await stats.incrementFailed()
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
    
    func incrementExported() { exported += 1 }
    func incrementUploaded() { uploaded += 1 }
    func incrementDuplicates() { duplicates += 1 }
    func incrementFailed() { failed += 1 }
    func incrementSkipped() { skipped += 1 }
    
    func getStats() -> (exported: Int, uploaded: Int, duplicates: Int, failed: Int, skipped: Int) {
        (exported, uploaded, duplicates, failed, skipped)
    }
}
