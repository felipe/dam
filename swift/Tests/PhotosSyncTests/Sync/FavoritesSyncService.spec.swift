import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("FavoritesSyncService Tests")
struct FavoritesSyncServiceSpec {

    // MARK: - Test 1: Sync when Photos favorite is newer than Immich

    @Test("Syncs Photos to Immich when Photos modification is newer")
    func syncPhotosNewerThanImmich() {
        // Photos was modified more recently than Immich
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now  // Newer
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: now.addingTimeInterval(-60)  // 1 minute older
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .photosToImmich)
    }

    // MARK: - Test 2: Sync when Immich favorite is newer than Photos

    @Test("Syncs Immich to Photos when Immich modification is newer")
    func syncImmichNewerThanPhotos() {
        // Immich was modified more recently than Photos
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: now.addingTimeInterval(-60)  // 1 minute older
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now  // Newer
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .immichToPhotos)
    }

    // MARK: - Test 3: Tiebreaker - Photos wins when timestamps equal

    @Test("Photos wins as tiebreaker when timestamps are equal")
    func photosTiebreaker() {
        // Same modification time - Photos wins
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: now  // Same time
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .photosToImmich)
    }

    // MARK: - Test 4: No change when states are the same

    @Test("No change when favorite states are the same")
    func noChangeWhenSame() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now.addingTimeInterval(-60)
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .noChange)
    }

    // MARK: - Test 5: Photos wins when Immich has nil modification date

    @Test("Photos wins when Immich has no modification date")
    func photosWinsWithNilImmichDate() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: nil  // No date
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .photosToImmich)
    }

    // MARK: - Test 6: Photos wins when both have nil modification dates

    @Test("Photos wins when both have nil modification dates")
    func photosWinsWithBothNilDates() {
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: nil
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: nil
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        // With both nil dates, both become distantPast, so they're equal
        // Photos wins as tiebreaker
        #expect(action == .photosToImmich)
    }

    // MARK: - Additional Edge Case Tests (Task Group 6)

    // Test 7: Unfavorite sync from Photos to Immich (Photos newer)
    @Test("Unfavorite syncs from Photos to Immich when Photos is newer")
    func unfavoritePhotosToImmich() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: false,  // Unfavorited in Photos
            modifiedAt: now  // Newer
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: true,  // Still favorite in Immich
            modifiedAt: now.addingTimeInterval(-60)  // Older
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .photosToImmich)
    }

    // Test 8: Unfavorite sync from Immich to Photos (Immich newer)
    @Test("Unfavorite syncs from Immich to Photos when Immich is newer")
    func unfavoriteImmichToPhotos() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,  // Still favorite in Photos
            modifiedAt: now.addingTimeInterval(-60)  // Older
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,  // Unfavorited in Immich
            modifiedAt: now  // Newer
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .immichToPhotos)
    }

    // Test 9: Immich wins when Photos has nil date but Immich has date
    @Test("Immich wins when Photos has nil date but Immich has valid date")
    func immichWinsWithNilPhotosDate() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: nil  // No date - becomes distantPast
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now  // Valid date, newer than distantPast
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        // Immich has a valid date (now) which is newer than distantPast
        #expect(action == .immichToPhotos)
    }

    // Test 10: No change when both unfavorited
    @Test("No change when both platforms have unfavorited state")
    func noChangeWhenBothUnfavorited() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: now
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: false,
            modifiedAt: now.addingTimeInterval(-60)
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .noChange)
    }

    // Test 11: Asset favorited in both platforms simultaneously (same timestamp, same state)
    @Test("No change when asset favorited in both platforms with same state")
    func assetFavoritedBothPlatformsSameState() {
        let now = Date()
        let photosState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now
        )
        let immichState = FavoritesSyncService.FavoriteState(
            isFavorite: true,
            modifiedAt: now
        )

        let action = FavoritesSyncService.resolveConflict(
            photosState: photosState,
            immichState: immichState
        )

        #expect(action == .noChange)
    }

    // MARK: - SyncSummary Tests

    @Test("SyncSummary initializes correctly")
    func syncSummaryInit() {
        let summary = FavoritesSyncService.SyncSummary(
            photosToImmich: 5,
            immichToPhotos: 3,
            conflictsResolved: 2,
            noChange: 10,
            failures: 1,
            total: 19
        )

        #expect(summary.photosToImmich == 5)
        #expect(summary.immichToPhotos == 3)
        #expect(summary.conflictsResolved == 2)
        #expect(summary.noChange == 10)
        #expect(summary.failures == 1)
        #expect(summary.total == 19)
    }

    @Test("SyncSummary default values are zero")
    func syncSummaryDefaults() {
        let summary = FavoritesSyncService.SyncSummary()

        #expect(summary.photosToImmich == 0)
        #expect(summary.immichToPhotos == 0)
        #expect(summary.conflictsResolved == 0)
        #expect(summary.noChange == 0)
        #expect(summary.failures == 0)
        #expect(summary.total == 0)
    }

    // MARK: - FavoriteState Tests

    @Test("FavoriteState stores values correctly")
    func favoriteStateInit() {
        let now = Date()
        let state = FavoritesSyncService.FavoriteState(isFavorite: true, modifiedAt: now)

        #expect(state.isFavorite == true)
        #expect(state.modifiedAt == now)
    }

    @Test("FavoriteState handles nil modifiedAt")
    func favoriteStateNilDate() {
        let state = FavoritesSyncService.FavoriteState(isFavorite: false, modifiedAt: nil)

        #expect(state.isFavorite == false)
        #expect(state.modifiedAt == nil)
    }

    // MARK: - SyncAction Tests

    @Test("SyncAction has correct raw values")
    func syncActionRawValues() {
        #expect(FavoritesSyncService.SyncAction.photosToImmich.rawValue == "Photos -> Immich")
        #expect(FavoritesSyncService.SyncAction.immichToPhotos.rawValue == "Immich -> Photos")
        #expect(FavoritesSyncService.SyncAction.noChange.rawValue == "No Change")
        #expect(FavoritesSyncService.SyncAction.conflict.rawValue == "Conflict")
        #expect(FavoritesSyncService.SyncAction.skipped.rawValue == "Skipped")
    }

    // MARK: - SyncResult Tests

    @Test("SyncResult stores all fields correctly")
    func syncResultInit() {
        let result = FavoritesSyncService.SyncResult(
            uuid: "test-uuid-123",
            immichId: "immich-456",
            action: .photosToImmich,
            success: true,
            error: nil
        )

        #expect(result.uuid == "test-uuid-123")
        #expect(result.immichId == "immich-456")
        #expect(result.action == .photosToImmich)
        #expect(result.success == true)
        #expect(result.error == nil)
    }

    @Test("SyncResult handles failure with error message")
    func syncResultWithError() {
        let result = FavoritesSyncService.SyncResult(
            uuid: "failed-uuid",
            immichId: nil,
            action: .skipped,
            success: false,
            error: "Network timeout"
        )

        #expect(result.uuid == "failed-uuid")
        #expect(result.immichId == nil)
        #expect(result.action == .skipped)
        #expect(result.success == false)
        #expect(result.error == "Network timeout")
    }
}
