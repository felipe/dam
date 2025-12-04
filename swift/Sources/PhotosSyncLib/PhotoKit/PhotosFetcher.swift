@preconcurrency import Foundation
@preconcurrency import Dispatch
import Photos

/// Fetches and downloads photos from the Photos library via PhotoKit
public final class PhotosFetcher: Sendable {
    
    public struct AssetInfo: Sendable {
        public let localIdentifier: String
        public let filename: String
        public let mediaType: PHAssetMediaType
        public let creationDate: Date?
        public let modificationDate: Date?
        public let isLocal: Bool  // Original is available locally
    }
    
    public struct DownloadResult: Sendable {
        public let localIdentifier: String
        public let filename: String
        public let fileURL: URL?
        public let fileSize: Int64
        public let mediaType: String
        public let error: String?
        
        public var success: Bool { fileURL != nil }
    }
    
    /// Request Photos library access
    public static func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            // Use withCheckedContinuation for proper async handling
            let newStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            print("Photos access denied. Grant access in System Settings → Privacy & Security → Photos")
            return false
        @unknown default:
            return false
        }
    }
    
    /// Get all assets from the library (fast - doesn't check local status)
    public static func getAllAssets() -> [AssetInfo] {
        var assets: [AssetInfo] = []
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeHiddenAssets = false
        
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        
        fetchResult.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let originalResource = resources.first { $0.type == .photo || $0.type == .video }
            var filename = originalResource?.originalFilename ?? ""
            
            // Fallback filename if empty
            if filename.isEmpty {
                let ext: String
                switch asset.mediaType {
                case .image: ext = "jpg"
                case .video: ext = "mov"
                default: ext = "dat"
                }
                filename = "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_")).\(ext)"
            }
            
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
    public static func isAssetLocal(_ identifier: String) -> Bool {
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
    public static func countLocalAssets(sampleSize: Int = 100) -> (local: Int, total: Int, estimated: Int) {
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
    public static func downloadAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
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
        
        // Get filename, fallback to UUID + extension if empty
        var filename = resource.originalFilename
        if filename.isEmpty {
            let ext: String
            switch asset.mediaType {
            case .image: ext = "jpg"
            case .video: ext = "mov"
            default: ext = "dat"
            }
            filename = "\(identifier.replacingOccurrences(of: "/", with: "_")).\(ext)"
        }
        let destURL = stagingDir.appendingPathComponent(filename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)
        
        // Capture values to avoid mutable variable issues in closures
        let finalFilename = filename
        let mediaType = mediaTypeString(asset.mediaType)
        
        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork
            
            // Use a class to safely track completion state across closures
            final class CompletionState: @unchecked Sendable {
                var completed = false
                let lock = NSLock()
                
                func tryComplete() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if completed { return false }
                    completed = true
                    return true
                }
            }
            let state = CompletionState()
            
            // Set up timeout
            let timeoutWork = DispatchWorkItem { [state] in
                guard state.tryComplete() else { return }
                continuation.resume(returning: DownloadResult(
                    localIdentifier: identifier,
                    filename: finalFilename,
                    fileURL: nil,
                    fileSize: 0,
                    mediaType: mediaType,
                    error: "Download timed out after \(Int(timeout))s"
                ))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destURL,
                options: options
            ) { [state] error in
                timeoutWork.cancel()
                
                guard state.tryComplete() else { return }
                
                if let error = error {
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: finalFilename,
                        fileURL: nil,
                        fileSize: 0,
                        mediaType: mediaType,
                        error: error.localizedDescription
                    ))
                } else {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: finalFilename,
                        fileURL: destURL,
                        fileSize: fileSize,
                        mediaType: mediaType,
                        error: nil
                    ))
                }
            }
        }
    }
    
    /// Get asset creation/modification dates
    public static func getAssetDates(identifier: String) -> (created: Date?, modified: Date?) {
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
