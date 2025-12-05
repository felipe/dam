import PhotosSyncLib
import ArgumentParser
import Foundation
import Photos

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show sync status and progress"
    )
    
    func run() async throws {
        print("photos-sync status starting...")
        print("Requesting Photos access...")
        
        // Force flush stdout
        fflush(stdout)
        
        guard await PhotosFetcher.requestAccess() else {
            print("ERROR: Photos access denied. Grant access in System Settings → Privacy → Photos")
            throw ExitCode.failure
        }
        print("Photos access granted")
        
        guard let config = Config.load() else {
            throw ExitCode.failure
        }
        
        print("Loading Photos library...")
        let assets = PhotosFetcher.getAllAssets()
        let totalAssets = assets.count
        
        let tracker = try Tracker(dbPath: config.trackerDBPath)
        let importedUUIDs = tracker.getImportedUUIDs()
        let stats = tracker.getStats()
        
        // Count already imported
        var alreadyImported = 0
        for asset in assets {
            if importedUUIDs.contains(asset.localIdentifier) {
                alreadyImported += 1
            }
        }
        
        // Sample to estimate local vs cloud (checking every asset is too slow)
        print("Sampling local availability...")
        let (sampleLocal, sampleTotal, estimatedLocal) = PhotosFetcher.countLocalAssets(sampleSize: 50)
        let estimatedCloud = totalAssets - estimatedLocal
        let readyToImport = max(0, estimatedLocal - alreadyImported)
        
        // Test Immich connection
        let immich = ImmichClient(baseURL: config.immichURL, apiKey: config.immichAPIKey)
        let immichOnline = await immich.ping()
        
        print()
        print(String(repeating: "=", count: 50))
        print("PHOTOS SYNC STATUS")
        print(String(repeating: "=", count: 50))
        print()
        print("Photos Library:")
        print("  Total assets:      \(formatNumber(totalAssets))")
        print("  Downloaded:        ~\(formatNumber(estimatedLocal)) (estimated from \(sampleLocal)/\(sampleTotal) sample)")
        print("  Still in iCloud:   ~\(formatNumber(estimatedCloud))")
        print()
        print("Import Progress:")
        print("  Already in Immich: \(formatNumber(alreadyImported))")
        print("  Ready to import:   ~\(formatNumber(readyToImport))")
        print("  Need download:     ~\(formatNumber(estimatedCloud))")
        print()
        print("Tracker Stats:")
        print("  Total imported:    \(formatNumber(stats.total))")
        print("  Photos:            \(formatNumber(stats.photos))")
        print("  Videos:            \(formatNumber(stats.videos))")
        print("  Total size:        \(formatBytes(stats.totalBytes))")
        
        // Show problem assets if any
        let problemStats = tracker.getProblemStats()
        if problemStats.failed > 0 || problemStats.skipped > 0 {
            print()
            print("Problem Assets:")
            if problemStats.failed > 0 {
                print("  Failed:            \(formatNumber(problemStats.failed))")
            }
            if problemStats.skipped > 0 {
                print("  Skipped:           \(formatNumber(problemStats.skipped))")
            }
        }
        print()

        // Live Photo stats
        let livePhotoStats = tracker.getLivePhotoStats()
        if livePhotoStats.total > 0 {
            print("Live Photos:")
            print("  Total:             \(formatNumber(livePhotoStats.total))")
            print("  With motion video: \(formatNumber(livePhotoStats.withMotionVideo))")
            if livePhotoStats.needingRepair > 0 {
                print("  Needing repair:    \(formatNumber(livePhotoStats.needingRepair))")
            }
            print()
        }

        // Cinematic video stats
        let cinematicStats = tracker.getCinematicStats()
        if cinematicStats.total > 0 || countCinematic(assets) > 0 {
            let libraryCount = countCinematic(assets)
            print("Cinematic Videos:")
            print("  In library:        \(formatNumber(libraryCount))")
            print("  Imported:          \(formatNumber(cinematicStats.total))")
            print("  With sidecars:     \(formatNumber(cinematicStats.withSidecars))")
            if cinematicStats.needingRepair > 0 {
                print("  Needing repair:    \(formatNumber(cinematicStats.needingRepair))")
            }
            print()
        }

        print("Immich Server:")
        print("  URL:               \(config.immichURL)")
        print("  Status:            \(immichOnline ? "✓ Online" : "✗ Offline")")
        print()
        
        if readyToImport > 0 {
            print("Run 'photos-sync import' to import \(formatNumber(readyToImport)) ready files")
        }
        if estimatedCloud > 0 {
            print("Run 'photos-sync import --include-cloud' to download and import from iCloud")
        }
        if problemStats.failed > 0 {
            print("Run 'photos-sync review' to inspect \(formatNumber(problemStats.failed)) failed assets")
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

    private func countCinematic(_ assets: [PhotosFetcher.AssetInfo]) -> Int {
        assets.filter { $0.isCinematic }.count
    }
}
