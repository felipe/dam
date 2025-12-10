import Foundation

/// Service for bidirectional favorites sync between Photos and Immich
/// Coordinates sync operations between Photos, Immich, and the Tracker database
public final class FavoritesSyncService: Sendable {

    /// Result of a single asset's favorite sync operation
    public struct SyncResult: Sendable {
        public let uuid: String
        public let immichId: String?
        public let action: SyncAction
        public let success: Bool
        public let error: String?
    }

    /// The action taken during sync
    public enum SyncAction: String, Sendable {
        case photosToImmich = "Photos -> Immich"
        case immichToPhotos = "Immich -> Photos"
        case noChange = "No Change"
        case conflict = "Conflict"
        case skipped = "Skipped"
    }

    /// Summary of a sync operation
    public struct SyncSummary: Sendable {
        public let photosToImmich: Int
        public let immichToPhotos: Int
        public let conflictsResolved: Int
        public let noChange: Int
        public let failures: Int
        public let total: Int
        public let isDryRun: Bool
        public let previewItems: [PreviewItem]

        public init(
            photosToImmich: Int = 0,
            immichToPhotos: Int = 0,
            conflictsResolved: Int = 0,
            noChange: Int = 0,
            failures: Int = 0,
            total: Int = 0,
            isDryRun: Bool = false,
            previewItems: [PreviewItem] = []
        ) {
            self.photosToImmich = photosToImmich
            self.immichToPhotos = immichToPhotos
            self.conflictsResolved = conflictsResolved
            self.noChange = noChange
            self.failures = failures
            self.total = total
            self.isDryRun = isDryRun
            self.previewItems = previewItems
        }
    }

    /// Preview item showing what would be synced in dry-run mode
    public struct PreviewItem: Sendable {
        public let uuid: String
        public let filename: String?
        public let action: SyncAction
        public let fromFavorite: Bool
        public let toFavorite: Bool
        public let reason: String

        public init(uuid: String, filename: String?, action: SyncAction, fromFavorite: Bool, toFavorite: Bool, reason: String) {
            self.uuid = uuid
            self.filename = filename
            self.action = action
            self.fromFavorite = fromFavorite
            self.toFavorite = toFavorite
            self.reason = reason
        }
    }

    /// State of an asset's favorite status in a single platform
    public struct FavoriteState: Sendable {
        public let isFavorite: Bool
        public let modifiedAt: Date?

        public init(isFavorite: Bool, modifiedAt: Date?) {
            self.isFavorite = isFavorite
            self.modifiedAt = modifiedAt
        }
    }

    /// Determine which platform wins in a conflict
    /// - Parameters:
    ///   - photosState: The favorite state from Photos
    ///   - immichState: The favorite state from Immich
    /// - Returns: The SyncAction indicating which platform should be the source of truth
    public static func resolveConflict(
        photosState: FavoriteState,
        immichState: FavoriteState
    ) -> SyncAction {
        // If favorite status is the same, no change needed
        if photosState.isFavorite == immichState.isFavorite {
            return .noChange
        }

        // Get modification dates - use distant past if nil
        let photosDate = photosState.modifiedAt ?? Date.distantPast
        let immichDate = immichState.modifiedAt ?? Date.distantPast

        // Conflict resolution:
        // 1. If Immich modification date > Photos modification date: Immich wins
        // 2. If Photos modification date >= Immich modification date: Photos wins (tiebreaker)
        if immichDate > photosDate {
            return .immichToPhotos
        } else {
            // Photos wins when timestamps are equal or Photos is newer
            return .photosToImmich
        }
    }

    /// Sync favorites for a list of assets
    /// - Parameters:
    ///   - assets: List of assets to sync, each containing Photos state and Immich state
    ///   - immichClient: The Immich client for API calls
    ///   - tracker: The tracker database for persistence
    ///   - batchSize: Maximum batch size for Immich API calls
    /// - Returns: Summary of the sync operation
    public static func syncFavorites(
        assets: [(uuid: String, immichId: String?, photosState: FavoriteState, immichState: FavoriteState?)],
        immichClient: ImmichClient,
        tracker: Tracker,
        batchSize: Int = 50
    ) async -> SyncSummary {
        var photosToImmichCount = 0
        var immichToPhotosCount = 0
        var conflictsResolved = 0
        var noChangeCount = 0
        var failureCount = 0

        // Separate assets into those needing Immich updates vs Photos updates
        var immichUpdates: [(id: String, isFavorite: Bool, uuid: String)] = []
        var photosUpdates: [(uuid: String, isFavorite: Bool)] = []

        for asset in assets {
            guard let immichId = asset.immichId else {
                // Skip assets without Immich ID
                noChangeCount += 1
                continue
            }

            // If no Immich state, sync from Photos to Immich
            guard let immichState = asset.immichState else {
                immichUpdates.append((id: immichId, isFavorite: asset.photosState.isFavorite, uuid: asset.uuid))
                photosToImmichCount += 1
                continue
            }

            // Resolve conflict
            let action = resolveConflict(photosState: asset.photosState, immichState: immichState)

            switch action {
            case .photosToImmich:
                immichUpdates.append((id: immichId, isFavorite: asset.photosState.isFavorite, uuid: asset.uuid))
                photosToImmichCount += 1
                if asset.photosState.modifiedAt != nil && immichState.modifiedAt != nil {
                    conflictsResolved += 1
                }

            case .immichToPhotos:
                photosUpdates.append((uuid: asset.uuid, isFavorite: immichState.isFavorite))
                immichToPhotosCount += 1
                if asset.photosState.modifiedAt != nil && immichState.modifiedAt != nil {
                    conflictsResolved += 1
                }

            case .noChange:
                noChangeCount += 1

            case .conflict, .skipped:
                noChangeCount += 1
            }
        }

        // Apply Immich updates in batches
        if !immichUpdates.isEmpty {
            // Group by favorite status
            let toFavorite = immichUpdates.filter { $0.isFavorite }.map { $0.id }
            let toUnfavorite = immichUpdates.filter { !$0.isFavorite }.map { $0.id }

            if !toFavorite.isEmpty {
                let result = await immichClient.updateFavorites(ids: toFavorite, isFavorite: true, batchSize: batchSize)
                if !result.success {
                    failureCount += result.failureCount
                }
            }

            if !toUnfavorite.isEmpty {
                let result = await immichClient.updateFavorites(ids: toUnfavorite, isFavorite: false, batchSize: batchSize)
                if !result.success {
                    failureCount += result.failureCount
                }
            }

            // Update tracker with final state
            for update in immichUpdates {
                do {
                    try tracker.updateFavoriteStatus(uuid: update.uuid, isFavorite: update.isFavorite)
                } catch {
                    // Log but continue
                    print("  WARNING: Failed to update tracker for \(update.uuid): \(error.localizedDescription)")
                }
            }
        }

        // Apply Photos updates
        if !photosUpdates.isEmpty {
            // Group by favorite status
            let toFavorite = photosUpdates.filter { $0.isFavorite }.map { $0.uuid }
            let toUnfavorite = photosUpdates.filter { !$0.isFavorite }.map { $0.uuid }

            if !toFavorite.isEmpty {
                let results = await PhotosUpdater.updateFavorites(identifiers: toFavorite, isFavorite: true)
                for result in results {
                    if result.success {
                        do {
                            try tracker.updateFavoriteStatus(uuid: result.localIdentifier, isFavorite: true)
                        } catch {
                            print("  WARNING: Failed to update tracker for \(result.localIdentifier): \(error.localizedDescription)")
                        }
                    } else {
                        failureCount += 1
                        immichToPhotosCount -= 1
                    }
                }
            }

            if !toUnfavorite.isEmpty {
                let results = await PhotosUpdater.updateFavorites(identifiers: toUnfavorite, isFavorite: false)
                for result in results {
                    if result.success {
                        do {
                            try tracker.updateFavoriteStatus(uuid: result.localIdentifier, isFavorite: false)
                        } catch {
                            print("  WARNING: Failed to update tracker for \(result.localIdentifier): \(error.localizedDescription)")
                        }
                    } else {
                        failureCount += 1
                        immichToPhotosCount -= 1
                    }
                }
            }
        }

        return SyncSummary(
            photosToImmich: photosToImmichCount,
            immichToPhotos: immichToPhotosCount,
            conflictsResolved: conflictsResolved,
            noChange: noChangeCount,
            failures: failureCount,
            total: assets.count
        )
    }

    /// Sync favorites for imported assets during import flow
    /// - Parameters:
    ///   - importedAssets: List of assets that were just imported (uuid, immichId, photosIsFavorite, filename)
    ///   - immichClient: The Immich client for API calls
    ///   - tracker: The tracker database for persistence
    ///   - dryRun: If true, only preview what would be synced without making changes
    /// - Returns: Summary of the sync operation
    public static func syncFavoritesForImportedAssets(
        importedAssets: [(uuid: String, immichId: String, photosIsFavorite: Bool, filename: String?)],
        immichClient: ImmichClient,
        tracker: Tracker,
        dryRun: Bool = false
    ) async -> SyncSummary {
        // For newly imported assets, Photos is always the source of truth
        // We just need to update Immich and the tracker

        // Separate by favorite status
        let toFavorite = importedAssets.filter { $0.photosIsFavorite }
        let toUnfavorite = importedAssets.filter { !$0.photosIsFavorite }

        var photosToImmichCount = 0
        var failureCount = 0
        var previewItems: [PreviewItem] = []

        // In dry-run mode, just build preview
        if dryRun {
            for asset in toFavorite {
                previewItems.append(PreviewItem(
                    uuid: asset.uuid,
                    filename: asset.filename,
                    action: .photosToImmich,
                    fromFavorite: false,
                    toFavorite: true,
                    reason: "New import - Photos is source of truth"
                ))
            }
            // Non-favorites don't need sync (Immich default is unfavorited)
            let noChangeCount = toUnfavorite.count

            return SyncSummary(
                photosToImmich: toFavorite.count,
                immichToPhotos: 0,
                conflictsResolved: 0,
                noChange: noChangeCount,
                failures: 0,
                total: importedAssets.count,
                isDryRun: true,
                previewItems: previewItems
            )
        }

        // Update Immich
        if !toFavorite.isEmpty {
            let ids = toFavorite.map { $0.immichId }
            let result = await immichClient.updateFavorites(ids: ids, isFavorite: true)
            if result.success {
                photosToImmichCount += result.successCount
            } else {
                failureCount += result.failureCount
                photosToImmichCount += result.successCount
            }
        }

        // Non-favorites don't need explicit unfavorite call (Immich default is unfavorited)

        // Update tracker with final state
        for asset in importedAssets {
            do {
                try tracker.updateFavoriteStatus(uuid: asset.uuid, isFavorite: asset.photosIsFavorite)
            } catch {
                print("  WARNING: Failed to update tracker for \(asset.uuid): \(error.localizedDescription)")
            }
        }

        return SyncSummary(
            photosToImmich: photosToImmichCount,
            immichToPhotos: 0,
            conflictsResolved: 0,
            noChange: toUnfavorite.count,
            failures: failureCount,
            total: importedAssets.count
        )
    }

    /// Convenience overload without filename for backward compatibility
    public static func syncFavoritesForImportedAssets(
        importedAssets: [(uuid: String, immichId: String, photosIsFavorite: Bool)],
        immichClient: ImmichClient,
        tracker: Tracker,
        dryRun: Bool = false
    ) async -> SyncSummary {
        let assetsWithFilename = importedAssets.map { (uuid: $0.uuid, immichId: $0.immichId, photosIsFavorite: $0.photosIsFavorite, filename: nil as String?) }
        return await syncFavoritesForImportedAssets(
            importedAssets: assetsWithFilename,
            immichClient: immichClient,
            tracker: tracker,
            dryRun: dryRun
        )
    }
}
