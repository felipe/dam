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
        
        // Subtypes (from PHAssetMediaSubtype flags)
        public let isLivePhoto: Bool       // .photoLive
        public let isPortrait: Bool        // .photoDepthEffect
        public let isHDR: Bool             // .photoHDR
        public let isPanorama: Bool        // .photoPanorama
        public let isScreenshot: Bool      // .photoScreenshot
        public let isCinematic: Bool       // .videoCinematic
        public let isSlomo: Bool           // .videoHighFrameRate
        public let isTimelapse: Bool       // .videoTimelapse
        public let isSpatialVideo: Bool    // subtype & 0x400000
        public let isProRAW: Bool          // UTI = com.adobe.raw-image
        
        // Key field - from actual resource check, not subtype
        public let hasPairedVideo: Bool    // Has .pairedVideo resource (type 9)
    }
    
    public struct DownloadResult: Sendable {
        public let localIdentifier: String
        public let filename: String
        public let fileURL: URL?
        public let fileSize: Int64
        public let mediaType: String
        public let error: String?
        
        public var success: Bool { fileURL != nil }
        
        public init(localIdentifier: String, filename: String, fileURL: URL?, fileSize: Int64, mediaType: String, error: String?) {
            self.localIdentifier = localIdentifier
            self.filename = filename
            self.fileURL = fileURL
            self.fileSize = fileSize
            self.mediaType = mediaType
            self.error = error
        }
    }
    
    /// Result of downloading an asset with paired video (Live Photo, etc.)
    public struct PairedAssetDownloadResult: Sendable {
        public let localIdentifier: String
        public let imageResult: DownloadResult
        public let videoResult: DownloadResult?  // nil if video export failed
        
        public var success: Bool { imageResult.success }
        public var hasVideo: Bool { videoResult?.success ?? false }
    }
    
    /// Alias for backward compatibility
    public typealias LivePhotoDownloadResult = PairedAssetDownloadResult
    
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
            
            // Extract subtypes from PHAssetMediaSubtype flags
            let subtypes = asset.mediaSubtypes
            let isLivePhoto = subtypes.contains(.photoLive)
            let isPortrait = subtypes.contains(.photoDepthEffect)
            let isHDR = subtypes.contains(.photoHDR)
            let isPanorama = subtypes.contains(.photoPanorama)
            let isScreenshot = subtypes.contains(.photoScreenshot)
            let isCinematic = subtypes.contains(.videoCinematic)
            let isSlomo = subtypes.contains(.videoHighFrameRate)
            let isTimelapse = subtypes.contains(.videoTimelapse)
            let isSpatialVideo = (subtypes.rawValue & 0x400000) != 0
            
            // Check for ProRAW (DNG format)
            let isProRAW = resources.contains { $0.uniformTypeIdentifier == "com.adobe.raw-image" }
            
            // Check for actual paired video resource (type 9)
            let hasPairedVideo = resources.contains { $0.type == .pairedVideo }
            
            assets.append(AssetInfo(
                localIdentifier: asset.localIdentifier,
                filename: filename,
                mediaType: asset.mediaType,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                isLocal: false,
                isLivePhoto: isLivePhoto,
                isPortrait: isPortrait,
                isHDR: isHDR,
                isPanorama: isPanorama,
                isScreenshot: isScreenshot,
                isCinematic: isCinematic,
                isSlomo: isSlomo,
                isTimelapse: isTimelapse,
                isSpatialVideo: isSpatialVideo,
                isProRAW: isProRAW,
                hasPairedVideo: hasPairedVideo
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
    
    /// Download an asset with paired video - exports both image and paired video
    /// Works for Live Photos and other assets with .pairedVideo resource
    public static func downloadPairedAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
    ) async -> PairedAssetDownloadResult {
        // First, download the image using the standard method
        let imageResult = await downloadAsset(
            identifier: identifier,
            to: stagingDir,
            timeout: timeout,
            allowNetwork: allowNetwork
        )
        
        // If image download failed, return early
        guard imageResult.success else {
            return PairedAssetDownloadResult(
                localIdentifier: identifier,
                imageResult: imageResult,
                videoResult: nil
            )
        }
        
        // Now try to export the paired video
        let videoResult = await downloadPairedVideo(
            identifier: identifier,
            to: stagingDir,
            timeout: timeout,
            allowNetwork: allowNetwork
        )
        
        return PairedAssetDownloadResult(
            localIdentifier: identifier,
            imageResult: imageResult,
            videoResult: videoResult
        )
    }
    
    /// Alias for backward compatibility
    public static func downloadLivePhotoAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
    ) async -> PairedAssetDownloadResult {
        return await downloadPairedAsset(
            identifier: identifier,
            to: stagingDir,
            timeout: timeout,
            allowNetwork: allowNetwork
        )
    }
    
    /// Download just the paired video component
    private static func downloadPairedVideo(
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
                mediaType: "video",
                error: "Asset not found"
            )
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        
        // Find the paired video resource
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            return DownloadResult(
                localIdentifier: identifier,
                filename: "unknown",
                fileURL: nil,
                fileSize: 0,
                mediaType: "video",
                error: "No paired video resource found"
            )
        }
        
        // Generate video filename based on image filename
        var videoFilename = videoResource.originalFilename
        if videoFilename.isEmpty {
            // Use identifier with _video suffix
            videoFilename = "\(identifier.replacingOccurrences(of: "/", with: "_"))_video.mov"
        }
        let destURL = stagingDir.appendingPathComponent(videoFilename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)
        
        let finalFilename = videoFilename
        
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
                    mediaType: "video",
                    error: "Download timed out after \(Int(timeout))s"
                ))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            
            PHAssetResourceManager.default().writeData(
                for: videoResource,
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
                        mediaType: "video",
                        error: error.localizedDescription
                    ))
                } else {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    continuation.resume(returning: DownloadResult(
                        localIdentifier: identifier,
                        filename: finalFilename,
                        fileURL: destURL,
                        fileSize: fileSize,
                        mediaType: "video",
                        error: nil
                    ))
                }
            }
        }
    }
    
    /// Check if an asset has a paired video resource available
    public static func hasPairedVideoResource(identifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return false }
        
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .pairedVideo }
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
