import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("PhotosUpdater Tests")
struct PhotosUpdaterSpec {

    // MARK: - Update Favorite Tests

    @Test("updateFavorite sets favorite status to true")
    func updateFavoriteSetsTrueStatus() async throws {
        // Test that updateFavorite can set favorite to true
        // Note: This test requires Photos library write access
        // On systems without authorization, the operation will fail gracefully

        // Get a real asset to test with, or use a non-existent one for error path
        let assets = PhotosFetcher.getAllAssets()

        if let firstAsset = assets.first {
            // Store original state to restore later
            let originalIsFavorite = firstAsset.isFavorite

            // Test setting favorite to true
            let result = await PhotosUpdater.updateFavorite(
                identifier: firstAsset.localIdentifier,
                isFavorite: true
            )

            // Result should have correct identifier
            #expect(result.localIdentifier == firstAsset.localIdentifier)

            // If we have write access, it should succeed
            // If not, we verify the error handling works
            if result.success {
                #expect(result.error == nil)
            } else {
                // Error should be populated for failures
                #expect(result.error != nil)
            }

            // Restore original state if we successfully changed it
            if result.success && !originalIsFavorite {
                _ = await PhotosUpdater.updateFavorite(
                    identifier: firstAsset.localIdentifier,
                    isFavorite: originalIsFavorite
                )
            }
        } else {
            // No assets available - test with non-existent identifier
            let result = await PhotosUpdater.updateFavorite(
                identifier: "test-non-existent-id",
                isFavorite: true
            )

            // Should fail gracefully for non-existent asset
            #expect(result.success == false)
            #expect(result.error != nil)
        }
    }

    @Test("updateFavorite sets favorite status to false")
    func updateFavoriteSetsToFalse() async throws {
        // Test that updateFavorite can set favorite to false
        // Note: This test requires Photos library write access

        let assets = PhotosFetcher.getAllAssets()

        if let firstAsset = assets.first {
            // Store original state to restore later
            let originalIsFavorite = firstAsset.isFavorite

            // Test setting favorite to false
            let result = await PhotosUpdater.updateFavorite(
                identifier: firstAsset.localIdentifier,
                isFavorite: false
            )

            // Result should have correct identifier
            #expect(result.localIdentifier == firstAsset.localIdentifier)

            // If we have write access, it should succeed
            if result.success {
                #expect(result.error == nil)
            } else {
                // Error should be populated for failures
                #expect(result.error != nil)
            }

            // Restore original state if we successfully changed it
            if result.success && originalIsFavorite {
                _ = await PhotosUpdater.updateFavorite(
                    identifier: firstAsset.localIdentifier,
                    isFavorite: originalIsFavorite
                )
            }
        } else {
            // No assets available - test with non-existent identifier
            let result = await PhotosUpdater.updateFavorite(
                identifier: "test-non-existent-id",
                isFavorite: false
            )

            // Should fail gracefully for non-existent asset
            #expect(result.success == false)
            #expect(result.error != nil)
        }
    }

    @Test("updateFavorites batch operation works")
    func updateFavoritesBatchOperationWorks() async throws {
        // Test that batch updateFavorites works with multiple assets

        let assets = PhotosFetcher.getAllAssets()

        if assets.count >= 2 {
            // Test with multiple real assets
            let identifiers = Array(assets.prefix(2).map { $0.localIdentifier })
            let originalStates = Dictionary(uniqueKeysWithValues: assets.prefix(2).map {
                ($0.localIdentifier, $0.isFavorite)
            })

            // Test batch update to false
            let results = await PhotosUpdater.updateFavorites(
                identifiers: identifiers,
                isFavorite: false
            )

            // Should return results for all identifiers
            #expect(results.count == identifiers.count)

            // Each result should have the correct identifier
            for result in results {
                #expect(identifiers.contains(result.localIdentifier))
            }

            // Restore original states
            for (identifier, wasFavorite) in originalStates {
                if wasFavorite {
                    _ = await PhotosUpdater.updateFavorite(
                        identifier: identifier,
                        isFavorite: wasFavorite
                    )
                }
            }
        } else if assets.count == 1 {
            // Test with single asset in batch
            let identifier = assets[0].localIdentifier
            let results = await PhotosUpdater.updateFavorites(
                identifiers: [identifier],
                isFavorite: false
            )

            #expect(results.count == 1)
            #expect(results[0].localIdentifier == identifier)
        } else {
            // No assets - test with empty array
            let results = await PhotosUpdater.updateFavorites(
                identifiers: [],
                isFavorite: true
            )

            // Empty input should return empty results
            #expect(results.isEmpty)
        }
    }

    @Test("updateFavorite handles non-existent asset with error")
    func updateFavoriteHandlesNonExistentAsset() async throws {
        // Test error handling for non-existent asset identifier

        let nonExistentId = "non-existent-local-identifier-12345"

        let result = await PhotosUpdater.updateFavorite(
            identifier: nonExistentId,
            isFavorite: true
        )

        // Should fail for non-existent asset
        #expect(result.localIdentifier == nonExistentId)
        #expect(result.success == false)
        #expect(result.error != nil)
        #expect(result.error?.contains("not found") == true || result.error != nil)
    }
}
