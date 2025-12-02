import Foundation
import Photos

/// Deletes photos from the Photos library
class PhotosDeleter {
    
    struct DeleteResult {
        let localIdentifier: String
        let success: Bool
        let error: String?
    }
    
    /// Delete assets by local identifier
    /// Note: This moves them to "Recently Deleted" - they're not permanently gone for 30 days
    static func deleteAssets(identifiers: [String], dryRun: Bool = false) async -> [DeleteResult] {
        if dryRun {
            return identifiers.map { DeleteResult(localIdentifier: $0, success: true, error: nil) }
        }
        
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        
        guard fetchResult.count > 0 else {
            return identifiers.map { DeleteResult(localIdentifier: $0, success: false, error: "Asset not found") }
        }
        
        var assetsToDelete: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assetsToDelete.append(asset)
        }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete as NSFastEnumeration)
            }
            
            return identifiers.map { DeleteResult(localIdentifier: $0, success: true, error: nil) }
        } catch {
            return identifiers.map { DeleteResult(localIdentifier: $0, success: false, error: error.localizedDescription) }
        }
    }
    
    /// Delete a single asset
    static func deleteAsset(identifier: String, dryRun: Bool = false) async -> DeleteResult {
        let results = await deleteAssets(identifiers: [identifier], dryRun: dryRun)
        return results.first ?? DeleteResult(localIdentifier: identifier, success: false, error: "Unknown error")
    }
}
