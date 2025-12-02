import Foundation
import Photos

/// Fetches and downloads photos from the Photos library via PhotoKit
class PhotosFetcher {
    
    struct AssetInfo {
        let localIdentifier: String
        let filename: String
        let mediaType: PHAssetMediaType
        let creationDate: Date?
        let modificationDate: Date?
        let isLocal: Bool  // Original is available locally
    }
    
    struct DownloadResult {
        let localIdentifier: String
        let filename: String
        let fileURL: URL?
        let fileSize: Int64
        let mediaType: String
        let error: String?
        
        var success: Bool { fileURL != nil }
    }
    
    /// Request Photos library access
    static func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            // Use semaphore for CLI compatibility
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                granted = (newStatus == .authorized || newStatus == .limited)
                semaphore.signal()
            }
            
            // Wait up to 60 seconds for user to respond to permission dialog
            let result = semaphore.wait(timeout: .now() + 60)
            if result == .timedOut {
                print("Permission request timed out. Please grant Photos access in System Settings.")
                return false
            }
            return granted
        case .denied, .restricted:
            print("Photos access denied. Grant access in System Settings → Privacy & Security → Photos")
            return false
        @unknown default:
            return false
        }
    }
    
    /// Get all assets from the library (fast - doesn't check local status)
    static func getAllAssets() -> [AssetInfo] {
        var assets: [AssetInfo] = []
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeHiddenAssets = false
        
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        
        fetchResult.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let originalResource = resources.first { $0.type == .photo || $0.type == .video }
            let filename = originalResource?.originalFilename ?? "unknown"
            
            assets.append(AssetInfo(
                localIdentifier: asset.localIdentifier,
                filename: filename,
                mediaType: asset.mediaType,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                isLocal: false  // Will check lazily during download
            ))
        }
        
        return assets
    }
    
    /// Check if an asset is available locally (synchronous)
    static func isAssetLocal(_ identifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return false }
        
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else {
            return false
        }
        
        var isLocal = false
        let semaphore = DispatchSemaphore(value: 0)
        
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        
        var gotData = false
        PHAssetResourceManager.default().requestData(for: resource, options: options) { _ in
            gotData = true
        } completionHandler: { error in
            isLocal = (error == nil && gotData)
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 2.0)
        return isLocal
    }
    
    /// Get count of locally available assets (samples for speed)
    static func countLocalAssets(sampleSize: Int = 100) -> (local: Int, total: Int, estimated: Int) {
        let allAssets = getAllAssets()
        let total = allAssets.count
        
        if total == 0 { return (0, 0, 0) }
        
        // Sample random assets to estimate local percentage
        let sampleCount = min(sampleSize, total)
        var localCount = 0
        
        let sampledIndices = (0..<total).shuffled().prefix(sampleCount)
        for idx in sampledIndices {
            if isAssetLocal(allAssets[idx].localIdentifier) {
                localCount += 1
            }
        }
        
        let localPercentage = Double(localCount) / Double(sampleCount)
        let estimatedLocal = Int(Double(total) * localPercentage)
        
        return (localCount, total, estimatedLocal)
    }
    
    /// Download original asset to staging directory
    static func downloadAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300
    ) async -> DownloadResult {
        // Fetch the asset
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            return DownloadResult(
                localIdentifier: identifier,
                filename: "unknown",
                fileURL: nil,
                fileSize: 0,
                mediaType: "unknown",
                error: "Asset not found"
            )
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { 
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }) ?? resources.first else {
            return DownloadResult(
                localIdentifier: identifier,
                filename: "unknown",
                fileURL: nil,
                fileSize: 0,
                mediaType: mediaTypeString(asset.mediaType),
                error: "No resource found"
            )
        }
        
        let filename = resource.originalFilename
        let destURL = stagingDir.appendingPathComponent(filename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)
        
        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true  // Allow iCloud download
            
            // Set up timeout
            var completed = false
            let timeoutWork = DispatchWorkItem {
                if !completed {
                    completed = true
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: filename,
                        fileURL: nil,
                        fileSize: 0,
                        mediaType: mediaTypeString(asset.mediaType),
                        error: "Download timed out after \(Int(timeout))s"
                    ))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destURL,
                options: options
            ) { error in
                timeoutWork.cancel()
                
                guard !completed else { return }
                completed = true
                
                if let error = error {
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: filename,
                        fileURL: nil,
                        fileSize: 0,
                        mediaType: mediaTypeString(asset.mediaType),
                        error: error.localizedDescription
                    ))
                } else {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: filename,
                        fileURL: destURL,
                        fileSize: fileSize,
                        mediaType: mediaTypeString(asset.mediaType),
                        error: nil
                    ))
                }
            }
        }
    }
    
    /// Get asset creation/modification dates
    static func getAssetDates(identifier: String) -> (created: Date?, modified: Date?) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            return (nil, nil)
        }
        return (asset.creationDate, asset.modificationDate)
    }
    
    private static func mediaTypeString(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
}
