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
    
    @Option(name: .long, help: "Maximum number of photos to process (0 = unlimited)")
    var limit: Int = 0
    
    @Option(name: .long, help: "Number of concurrent downloads")
    var concurrency: Int = 3
    
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
        var candidates = allAssets.filter { !importedUUIDs.contains($0.localIdentifier) }
        print("Not yet imported: \(formatNumber(candidates.count))")
        
        // Filter by local/cloud if needed
        var toImport: [PhotosFetcher.AssetInfo] = []
        if !includeCloud {
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
        } else {
            toImport = candidates
            // Apply limit
            if limit > 0 && toImport.count > limit {
                toImport = Array(toImport.prefix(limit))
            }
        }
        
        print("Assets to import: \(formatNumber(toImport.count))")
        
        if toImport.isEmpty {
            print("Nothing to import.")
            return
        }
        
        print()
        print(String(repeating: "=", count: 50))
        print("IMPORTING \(formatNumber(toImport.count)) ASSETS")
        print(String(repeating: "=", count: 50))
        print()
        
        var stats = ImportStats()
        
        for (index, asset) in toImport.enumerated() {
            let num = index + 1
            print("[\(num)/\(toImport.count)] \(asset.filename)")
            
            if dryRun {
                print("  DRY RUN: Would download and upload")
                stats.skipped += 1
                continue
            }
            
            // Download the asset
            let isCloud = !asset.isLocal
            if isCloud {
                print("  Downloading from iCloud...")
            }
            
            let downloadResult = await PhotosFetcher.downloadAsset(
                identifier: asset.localIdentifier,
                to: config.stagingDir
            )
            
            if !downloadResult.success {
                print("  ERROR: \(downloadResult.error ?? "Download failed")")
                stats.failed += 1
                continue
            }
            
            guard let fileURL = downloadResult.fileURL else {
                print("  ERROR: No file URL")
                stats.failed += 1
                continue
            }
            
            stats.exported += 1
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
                    stats.duplicates += 1
                } else {
                    print("  Uploaded: \(uploadResult.assetID ?? "unknown")")
                    stats.uploaded += 1
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
                stats.failed += 1
            }
            
            // Delay between iCloud downloads to be gentle
            if isCloud && index < toImport.count - 1 && delay > 0 {
                print("  Waiting \(Int(delay))s before next download...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // Summary
        print()
        print(String(repeating: "=", count: 50))
        print("IMPORT COMPLETE")
        print(String(repeating: "=", count: 50))
        print("Exported:   \(formatNumber(stats.exported))")
        print("Uploaded:   \(formatNumber(stats.uploaded))")
        print("Duplicates: \(formatNumber(stats.duplicates))")
        print("Failed:     \(formatNumber(stats.failed))")
        if dryRun {
            print("Skipped:    \(formatNumber(stats.skipped)) (dry run)")
        }
        
        let finalStats = tracker.getStats()
        print()
        print("Total in Immich: \(formatNumber(finalStats.total)) (\(formatBytes(finalStats.totalBytes)))")
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

private struct ImportStats {
    var exported = 0
    var uploaded = 0
    var duplicates = 0
    var failed = 0
    var skipped = 0
}
