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
        public let isLivePhoto: Bool  // Contains paired video component
        public let isCinematic: Bool  // Cinematic video with depth/focus data
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
    
    /// Result of downloading a Live Photo (image + paired video)
    public struct LivePhotoDownloadResult: Sendable {
        public let localIdentifier: String
        public let imageResult: DownloadResult
        public let videoResult: DownloadResult?  // nil if video export failed

        public var success: Bool { imageResult.success }
        public var hasVideo: Bool { videoResult?.success ?? false }
    }

    /// Result of downloading a Cinematic video (main video + sidecars)
    public struct CinematicDownloadResult: Sendable {
        public let localIdentifier: String
        public let videoResult: DownloadResult           // Main MOV with depth track
        public let adjustmentDataResult: DownloadResult? // AAE sidecar
        public let baseVideoResult: DownloadResult?      // Pre-edit state (if edited)
        public let renderedVideoResult: DownloadResult?  // Baked effects (if edited)

        public var success: Bool { videoResult.success }
        public var hasAdjustmentData: Bool { adjustmentDataResult?.success ?? false }
        public var hasBaseVideo: Bool { baseVideoResult?.success ?? false }
        public var hasRenderedVideo: Bool { renderedVideoResult?.success ?? false }

        /// All successfully exported sidecar URLs (excluding main video)
        public var sidecarURLs: [URL] {
            var urls: [URL] = []
            if let url = adjustmentDataResult?.fileURL { urls.append(url) }
            if let url = baseVideoResult?.fileURL { urls.append(url) }
            if let url = renderedVideoResult?.fileURL { urls.append(url) }
            return urls
        }
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
            
            // Detect Live Photo via mediaSubtypes
            let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
            // Detect Cinematic video via mediaSubtypes
            let isCinematic = asset.mediaSubtypes.contains(.videoCinematic)

            assets.append(AssetInfo(
                localIdentifier: asset.localIdentifier,
                filename: filename,
                mediaType: asset.mediaType,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                isLocal: false,  // Will check lazily during download
                isLivePhoto: isLivePhoto,
                isCinematic: isCinematic
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
    
    /// Download a Live Photo asset - exports both image and paired video
    public static func downloadLivePhotoAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
    ) async -> LivePhotoDownloadResult {
        // First, download the image using the standard method
        let imageResult = await downloadAsset(
            identifier: identifier,
            to: stagingDir,
            timeout: timeout,
            allowNetwork: allowNetwork
        )
        
        // If image download failed, return early
        guard imageResult.success else {
            return LivePhotoDownloadResult(
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
        
        return LivePhotoDownloadResult(
            localIdentifier: identifier,
            imageResult: imageResult,
            videoResult: videoResult
        )
    }
    
    /// Download just the paired video component of a Live Photo
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
    
    /// Check if a Live Photo has a paired video resource available
    public static func hasPairedVideoResource(identifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return false }

        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .pairedVideo }
    }

    // MARK: - Cinematic Video Support

    /// Download a Cinematic video with all its resources (main video + sidecars)
    public static func downloadCinematicVideoAsset(
        identifier: String,
        to stagingDir: URL,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
    ) async -> CinematicDownloadResult {
        // First, download the main video using the standard method
        let videoResult = await downloadAsset(
            identifier: identifier,
            to: stagingDir,
            timeout: timeout,
            allowNetwork: allowNetwork
        )

        // If main video download failed, return early
        guard videoResult.success else {
            return CinematicDownloadResult(
                localIdentifier: identifier,
                videoResult: videoResult,
                adjustmentDataResult: nil,
                baseVideoResult: nil,
                renderedVideoResult: nil
            )
        }

        // Fetch the asset to get all resources
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            return CinematicDownloadResult(
                localIdentifier: identifier,
                videoResult: videoResult,
                adjustmentDataResult: nil,
                baseVideoResult: nil,
                renderedVideoResult: nil
            )
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let baseFilename = (videoResult.filename as NSString).deletingPathExtension

        // Download adjustment data (AAE sidecar)
        let adjustmentDataResult = await downloadResource(
            resources: resources,
            type: .adjustmentData,
            identifier: identifier,
            to: stagingDir,
            filenameOverride: "\(baseFilename).AAE",
            timeout: timeout,
            allowNetwork: allowNetwork
        )

        // Download adjustment base video (if exists - only for edited videos)
        let baseVideoResult = await downloadResource(
            resources: resources,
            type: .adjustmentBaseVideo,
            identifier: identifier,
            to: stagingDir,
            filenameOverride: "\(baseFilename)_base.MOV",
            timeout: timeout,
            allowNetwork: allowNetwork
        )

        // Download full size rendered video (if exists - only for edited videos)
        let renderedVideoResult = await downloadResource(
            resources: resources,
            type: .fullSizeVideo,
            identifier: identifier,
            to: stagingDir,
            filenameOverride: "\(baseFilename)_rendered.MOV",
            timeout: timeout,
            allowNetwork: allowNetwork
        )

        return CinematicDownloadResult(
            localIdentifier: identifier,
            videoResult: videoResult,
            adjustmentDataResult: adjustmentDataResult,
            baseVideoResult: baseVideoResult,
            renderedVideoResult: renderedVideoResult
        )
    }

    /// Check if an asset is a Cinematic video
    public static func isCinematicVideo(identifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return false }
        return asset.mediaSubtypes.contains(.videoCinematic)
    }

    /// Get info about Cinematic video resources
    public static func getCinematicResourceInfo(identifier: String) -> (hasAdjustmentData: Bool, hasBaseVideo: Bool, hasRenderedVideo: Bool) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            return (false, false, false)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let hasAdjustmentData = resources.contains { $0.type == .adjustmentData }
        let hasBaseVideo = resources.contains { $0.type == .adjustmentBaseVideo }
        let hasRenderedVideo = resources.contains { $0.type == .fullSizeVideo }

        return (hasAdjustmentData, hasBaseVideo, hasRenderedVideo)
    }

    /// Download a specific resource type from an asset
    private static func downloadResource(
        resources: [PHAssetResource],
        type: PHAssetResourceType,
        identifier: String,
        to stagingDir: URL,
        filenameOverride: String? = nil,
        timeout: TimeInterval = 300,
        allowNetwork: Bool = true
    ) async -> DownloadResult? {
        guard let resource = resources.first(where: { $0.type == type }) else {
            return nil  // Resource doesn't exist - not an error
        }

        let filename = filenameOverride ?? resource.originalFilename
        let destURL = stagingDir.appendingPathComponent(filename)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)

        let finalFilename = filename
        let mediaType = resourceTypeToMediaType(type)

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

    private static func resourceTypeToMediaType(_ type: PHAssetResourceType) -> String {
        switch type {
        case .video, .fullSizeVideo, .adjustmentBaseVideo:
            return "video"
        case .adjustmentData:
            return "sidecar"
        default:
            return "unknown"
        }
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
