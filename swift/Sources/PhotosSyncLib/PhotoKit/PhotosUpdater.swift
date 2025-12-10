import Foundation
import Photos

/// Updates metadata for photos in the Photos library
public final class PhotosUpdater: Sendable {

    /// Result of an update operation for a single asset
    public struct UpdateResult: Sendable {
        public let localIdentifier: String
        public let success: Bool
        public let error: String?
    }

    /// Update the favorite status for a single asset
    /// - Parameters:
    ///   - identifier: The local identifier of the PHAsset
    ///   - isFavorite: The new favorite status to set
    /// - Returns: UpdateResult indicating success or failure
    public static func updateFavorite(identifier: String, isFavorite: Bool) async -> UpdateResult {
        let results = await updateFavorites(identifiers: [identifier], isFavorite: isFavorite)
        return results.first ?? UpdateResult(
            localIdentifier: identifier,
            success: false,
            error: "Unknown error"
        )
    }

    /// Update the favorite status for multiple assets in a single operation
    /// - Parameters:
    ///   - identifiers: Array of local identifiers for PHAssets to update
    ///   - isFavorite: The new favorite status to set for all assets
    /// - Returns: Array of UpdateResult for each asset
    public static func updateFavorites(identifiers: [String], isFavorite: Bool) async -> [UpdateResult] {
        guard !identifiers.isEmpty else {
            return []
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

        guard fetchResult.count > 0 else {
            // No assets found - return failure for all identifiers
            return identifiers.map {
                UpdateResult(localIdentifier: $0, success: false, error: "Asset not found")
            }
        }

        // Collect found assets and track which identifiers were not found
        var assetsToUpdate: [PHAsset] = []
        var foundIdentifiers = Set<String>()

        fetchResult.enumerateObjects { asset, _, _ in
            assetsToUpdate.append(asset)
            foundIdentifiers.insert(asset.localIdentifier)
        }

        // Build results array
        var results: [UpdateResult] = []

        // Add failure results for identifiers that were not found
        for identifier in identifiers where !foundIdentifiers.contains(identifier) {
            results.append(UpdateResult(
                localIdentifier: identifier,
                success: false,
                error: "Asset not found"
            ))
        }

        // Perform the batch update for found assets
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in assetsToUpdate {
                    let changeRequest = PHAssetChangeRequest(for: asset)
                    changeRequest.isFavorite = isFavorite
                }
            }

            // Add success results for all found assets
            for asset in assetsToUpdate {
                results.append(UpdateResult(
                    localIdentifier: asset.localIdentifier,
                    success: true,
                    error: nil
                ))
            }
        } catch {
            // Add failure results for all found assets
            for asset in assetsToUpdate {
                results.append(UpdateResult(
                    localIdentifier: asset.localIdentifier,
                    success: false,
                    error: error.localizedDescription
                ))
            }
        }

        return results
    }
}
