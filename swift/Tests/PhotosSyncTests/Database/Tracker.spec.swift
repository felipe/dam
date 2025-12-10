import Testing
import Foundation
@testable import PhotosSyncLib

@Suite("Tracker Database Tests")
struct TrackerSpec {

    /// Create a tracker with a temporary database
    func createTestTracker() throws -> (Tracker, URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).db")
        let tracker = try Tracker(dbPath: dbPath)
        return (tracker, dbPath)
    }

    func cleanup(_ dbPath: URL) {
        try? FileManager.default.removeItem(at: dbPath)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath.path + "-shm"))
    }

    @Test("Creates database and tables successfully")
    func createsDatabase() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        #expect(FileManager.default.fileExists(atPath: dbPath.path))
        _ = tracker
    }

    @Test("Marks asset as imported and retrieves it")
    func markImportedAndRetrieve() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "test-uuid-123"
        let immichID = "immich-abc"

        #expect(!tracker.isImported(uuid: uuid))

        try tracker.markImported(
            uuid: uuid,
            immichID: immichID,
            filename: "photo.jpg",
            fileSize: 1024,
            mediaType: "photo"
        )

        #expect(tracker.isImported(uuid: uuid))
        #expect(tracker.getImmichIDForUUID(uuid) == immichID)
    }

    @Test("Gets all imported UUIDs")
    func getImportedUUIDs() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        #expect(tracker.getImportedUUIDs().isEmpty)

        try tracker.markImported(uuid: "uuid-1", immichID: "i1", filename: "a.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "uuid-2", immichID: "i2", filename: "b.jpg", fileSize: 200, mediaType: "photo")
        try tracker.markImported(uuid: "uuid-3", immichID: "i3", filename: "c.mov", fileSize: 300, mediaType: "video")

        let uuids = tracker.getImportedUUIDs()
        #expect(uuids.count == 3)
        #expect(uuids.contains("uuid-1"))
        #expect(uuids.contains("uuid-2"))
        #expect(uuids.contains("uuid-3"))
    }

    @Test("Calculates stats correctly")
    func getStats() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let emptyStats = tracker.getStats()
        #expect(emptyStats.total == 0)
        #expect(emptyStats.photos == 0)
        #expect(emptyStats.videos == 0)
        #expect(emptyStats.totalBytes == 0)

        try tracker.markImported(uuid: "p1", immichID: "i1", filename: "a.jpg", fileSize: 1000, mediaType: "photo")
        try tracker.markImported(uuid: "p2", immichID: "i2", filename: "b.jpg", fileSize: 2000, mediaType: "photo")
        try tracker.markImported(uuid: "v1", immichID: "i3", filename: "c.mov", fileSize: 5000, mediaType: "video")

        let stats = tracker.getStats()
        #expect(stats.total == 3)
        #expect(stats.photos == 2)
        #expect(stats.videos == 1)
        #expect(stats.totalBytes == 8000)
    }

    @Test("Marks asset as archived")
    func markArchived() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "archive-test"
        try tracker.markImported(uuid: uuid, immichID: "i1", filename: "x.jpg", fileSize: 100, mediaType: "photo")

        #expect(!tracker.isArchived(uuid: uuid))

        try tracker.markArchived(uuid: uuid)

        #expect(tracker.isArchived(uuid: uuid))
    }

    @Test("getActiveImportedUUIDs excludes archived assets")
    func activeUUIDsExcludeArchived() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markImported(uuid: "active-1", immichID: "i1", filename: "a.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "active-2", immichID: "i2", filename: "b.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "archived-1", immichID: "i3", filename: "c.jpg", fileSize: 100, mediaType: "photo")

        try tracker.markArchived(uuid: "archived-1")

        let activeUUIDs = tracker.getActiveImportedUUIDs()
        #expect(activeUUIDs.count == 2)
        #expect(activeUUIDs.contains("active-1"))
        #expect(activeUUIDs.contains("active-2"))
        #expect(!activeUUIDs.contains("archived-1"))

        let allUUIDs = tracker.getImportedUUIDs()
        #expect(allUUIDs.count == 3)
    }

    @Test("Removes asset from tracking")
    func removeAsset() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "to-remove"
        try tracker.markImported(uuid: uuid, immichID: "i1", filename: "x.jpg", fileSize: 100, mediaType: "photo")

        #expect(tracker.isImported(uuid: uuid))

        try tracker.removeAsset(uuid: uuid)

        #expect(!tracker.isImported(uuid: uuid))
        #expect(tracker.getImportedUUIDs().isEmpty)
    }

    @Test("Handles nil immichID")
    func nilImmichID() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "nil-immich"
        try tracker.markImported(uuid: uuid, immichID: nil, filename: "x.jpg", fileSize: 100, mediaType: "photo")

        #expect(tracker.isImported(uuid: uuid))
        #expect(tracker.getImmichIDForUUID(uuid) == nil)
    }

    @Test("Updates existing record on re-import")
    func updateOnReImport() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "update-test"

        try tracker.markImported(uuid: uuid, immichID: nil, filename: "x.jpg", fileSize: 100, mediaType: "photo")
        #expect(tracker.getImmichIDForUUID(uuid) == nil)

        try tracker.markImported(uuid: uuid, immichID: "new-immich-id", filename: "x.jpg", fileSize: 100, mediaType: "photo")
        #expect(tracker.getImmichIDForUUID(uuid) == "new-immich-id")

        #expect(tracker.getImportedUUIDs().count == 1)
    }

    // MARK: - Paired Video / Live Photo Tests

    @Test("Marks Live Photo with motion video using subtypes")
    func markLivePhotoWithMotionVideo() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "live-photo-1"
        let motionVideoID = "motion-video-immich-id"

        let subtypes = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: uuid,
            immichID: "photo-immich-id",
            filename: "live.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: subtypes,
            motionVideoImmichID: motionVideoID
        )

        #expect(tracker.isLivePhoto(uuid: uuid) == true)
        #expect(tracker.hasMotionVideoBackup(uuid: uuid) == true)
        #expect(tracker.getMotionVideoImmichID(uuid: uuid) == motionVideoID)
    }

    @Test("Marks Live Photo without motion video")
    func markLivePhotoWithoutMotionVideo() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "live-photo-no-video"

        let subtypes = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: uuid,
            immichID: "photo-id",
            filename: "live.heic",
            fileSize: 1500,
            mediaType: "photo",
            subtypes: subtypes,
            motionVideoImmichID: nil
        )

        #expect(tracker.isLivePhoto(uuid: uuid) == true)
        #expect(tracker.hasMotionVideoBackup(uuid: uuid) == false)
        #expect(tracker.getMotionVideoImmichID(uuid: uuid) == nil)
    }

    @Test("Regular photo is not a Live Photo")
    func regularPhotoNotLivePhoto() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "regular-photo"

        try tracker.markImported(
            uuid: uuid,
            immichID: "photo-id",
            filename: "regular.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        #expect(tracker.isLivePhoto(uuid: uuid) == false)
        #expect(tracker.hasMotionVideoBackup(uuid: uuid) == false)
    }

    @Test("getAssetsNeedingPairedVideoRepair finds assets without video backup")
    func getAssetsNeedingPairedVideoRepair() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Complete Live Photo with motion video - should NOT need repair
        let completeLiveSubtypes = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "complete-live",
            immichID: "i1",
            filename: "complete.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: completeLiveSubtypes,
            motionVideoImmichID: "motion-1"
        )

        // Live Photo without motion video - SHOULD need repair
        let incompleteLiveSubtypes = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "incomplete-live",
            immichID: "i2",
            filename: "incomplete.heic",
            fileSize: 1500,
            mediaType: "photo",
            subtypes: incompleteLiveSubtypes,
            motionVideoImmichID: nil
        )

        // Regular photo - should NOT need repair
        try tracker.markImported(
            uuid: "regular",
            immichID: "i3",
            filename: "regular.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        let needingRepair = tracker.getAssetsNeedingPairedVideoRepair()

        #expect(needingRepair.count == 1)
        #expect(needingRepair[0].uuid == "incomplete-live")
        #expect(needingRepair[0].immichID == "i2")
        #expect(needingRepair[0].filename == "incomplete.heic")
    }

    @Test("updateLivePhotoInfo updates existing asset")
    func updateLivePhotoInfo() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let uuid = "update-live-photo"

        // Initially import without Live Photo info
        try tracker.markImported(
            uuid: uuid,
            immichID: "photo-id",
            filename: "photo.heic",
            fileSize: 2000,
            mediaType: "photo"
        )

        #expect(tracker.isLivePhoto(uuid: uuid) == false)
        #expect(tracker.hasMotionVideoBackup(uuid: uuid) == false)

        // Update with Live Photo info
        try tracker.updateLivePhotoInfo(
            uuid: uuid,
            isLivePhoto: true,
            motionVideoImmichID: "motion-video-id"
        )

        #expect(tracker.isLivePhoto(uuid: uuid) == true)
        #expect(tracker.hasMotionVideoBackup(uuid: uuid) == true)
        #expect(tracker.getMotionVideoImmichID(uuid: uuid) == "motion-video-id")
    }

    @Test("getLivePhotoStats returns correct counts")
    func getLivePhotoStats() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Complete Live Photo
        let completeSub = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "live-1",
            immichID: "i1",
            filename: "a.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: completeSub,
            motionVideoImmichID: "motion-1"
        )

        // Complete Live Photo
        try tracker.markImported(
            uuid: "live-2",
            immichID: "i2",
            filename: "b.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: completeSub,
            motionVideoImmichID: "motion-2"
        )

        // Incomplete Live Photo (no motion video)
        let incompleteSub = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "live-3",
            immichID: "i3",
            filename: "c.heic",
            fileSize: 1500,
            mediaType: "photo",
            subtypes: incompleteSub,
            motionVideoImmichID: nil
        )

        // Regular photo
        try tracker.markImported(
            uuid: "regular",
            immichID: "i4",
            filename: "d.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        let stats = tracker.getLivePhotoStats()

        #expect(stats.total == 3)  // 3 Live Photos
        #expect(stats.withMotionVideo == 2)  // 2 with motion video
        #expect(stats.needingRepair == 1)  // 1 without motion video
    }

    @Test("Migration adds subtype columns to existing database")
    func migrationAddsSubtypeColumns() throws {
        // Create tracker - migration runs on init
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import using all subtype columns
        let subtypes = Tracker.AssetSubtypes(
            isLivePhoto: true,
            isPortrait: true,
            hasPairedVideo: true
        )
        try tracker.markImported(
            uuid: "test",
            immichID: "i1",
            filename: "test.heic",
            fileSize: 1000,
            mediaType: "photo",
            subtypes: subtypes,
            motionVideoImmichID: "motion-id"
        )

        #expect(tracker.isLivePhoto(uuid: "test") == true)
        #expect(tracker.hasPairedVideo(uuid: "test") == true)
        #expect(tracker.getMotionVideoImmichID(uuid: "test") == "motion-id")
    }

    @Test("Paired video stats include non-Live assets")
    func getPairedVideoStats() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Live Photo with motion video
        let liveSub = Tracker.AssetSubtypes(isLivePhoto: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "live-1",
            immichID: "i1",
            filename: "live.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: liveSub,
            motionVideoImmichID: "motion-1"
        )

        // Non-Live with paired video (e.g., highFPS photo) - needs repair
        let nonLiveSub = Tracker.AssetSubtypes(isLivePhoto: false, isSlomo: true, hasPairedVideo: true)
        try tracker.markImported(
            uuid: "slomo-photo",
            immichID: "i2",
            filename: "slomo.heic",
            fileSize: 1500,
            mediaType: "photo",
            subtypes: nonLiveSub,
            motionVideoImmichID: nil
        )

        let stats = tracker.getPairedVideoStats()

        #expect(stats.total == 2)  // Both have paired video
        #expect(stats.withMotionVideo == 1)  // Only Live Photo has backup
        #expect(stats.needingRepair == 1)  // Slomo needs repair
    }

    @Test("Subtype stats track all types")
    func getSubtypeStats() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markImported(
            uuid: "portrait-1",
            immichID: "i1",
            filename: "portrait.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: Tracker.AssetSubtypes(isPortrait: true)
        )

        try tracker.markImported(
            uuid: "portrait-2",
            immichID: "i2",
            filename: "portrait2.heic",
            fileSize: 2000,
            mediaType: "photo",
            subtypes: Tracker.AssetSubtypes(isPortrait: true)
        )

        try tracker.markImported(
            uuid: "hdr-1",
            immichID: "i3",
            filename: "hdr.jpg",
            fileSize: 1500,
            mediaType: "photo",
            subtypes: Tracker.AssetSubtypes(isHDR: true)
        )

        try tracker.markImported(
            uuid: "proraw-1",
            immichID: "i4",
            filename: "raw.dng",
            fileSize: 20000,
            mediaType: "photo",
            subtypes: Tracker.AssetSubtypes(isProRAW: true)
        )

        let stats = tracker.getSubtypeStats()

        #expect(stats.portrait == 2)
        #expect(stats.hdr == 1)
        #expect(stats.proraw == 1)
        #expect(stats.screenshot == 0)
        #expect(stats.cinematic == 0)
    }

    // MARK: - Problem Asset Tracking Tests

    @Test("markFailed records failed asset")
    func markFailed() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        let createdAt = Date()
        try tracker.markFailed(
            uuid: "failed-1",
            filename: "failed.jpg",
            mediaType: "photo",
            reason: "Upload timeout",
            createdAt: createdAt
        )

        let problems = tracker.getProblemAssets()
        #expect(problems.count == 1)
        #expect(problems[0].uuid == "failed-1")
        #expect(problems[0].filename == "failed.jpg")
        #expect(problems[0].status == "failed")
        #expect(problems[0].reason == "Upload timeout")
        #expect(problems[0].mediaType == "photo")
    }

    @Test("markSkipped records skipped asset")
    func markSkipped() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markSkipped(
            uuid: "skipped-1",
            filename: "cloud.jpg",
            mediaType: "photo",
            reason: "Asset in iCloud"
        )

        let problems = tracker.getProblemAssets()
        #expect(problems.count == 1)
        #expect(problems[0].status == "skipped")
        #expect(problems[0].reason == "Asset in iCloud")
    }

    @Test("getFailedAssets returns only failed")
    func getFailedAssets() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markFailed(uuid: "f1", filename: "f.jpg", mediaType: "photo", reason: "error1")
        try tracker.markSkipped(uuid: "s1", filename: "s.jpg", mediaType: "photo", reason: "skip1")
        try tracker.markFailed(uuid: "f2", filename: "f2.jpg", mediaType: "photo", reason: "error2")

        let failed = tracker.getFailedAssets()
        #expect(failed.count == 2)
        #expect(failed.allSatisfy { $0.status == "failed" })
    }

    @Test("getSkippedAssets returns only skipped")
    func getSkippedAssets() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markFailed(uuid: "f1", filename: "f.jpg", mediaType: "photo", reason: "error1")
        try tracker.markSkipped(uuid: "s1", filename: "s.jpg", mediaType: "photo", reason: "skip1")
        try tracker.markSkipped(uuid: "s2", filename: "s2.jpg", mediaType: "photo", reason: "skip2")

        let skipped = tracker.getSkippedAssets()
        #expect(skipped.count == 2)
        #expect(skipped.allSatisfy { $0.status == "skipped" })
    }

    @Test("getProblemStats returns correct counts")
    func getProblemStats() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markFailed(uuid: "f1", filename: "f.jpg", mediaType: "photo", reason: "err")
        try tracker.markFailed(uuid: "f2", filename: "f2.jpg", mediaType: "photo", reason: "err")
        try tracker.markSkipped(uuid: "s1", filename: "s.jpg", mediaType: "photo", reason: "skip")

        let stats = tracker.getProblemStats()
        #expect(stats.failed == 2)
        #expect(stats.skipped == 1)
    }

    @Test("isProblem returns true for failed/skipped assets")
    func isProblem() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markFailed(uuid: "failed-1", filename: "f.jpg", mediaType: "photo", reason: "err")
        try tracker.markSkipped(uuid: "skipped-1", filename: "s.jpg", mediaType: "photo", reason: "skip")

        #expect(tracker.isProblem(uuid: "failed-1") == true)
        #expect(tracker.isProblem(uuid: "skipped-1") == true)
        #expect(tracker.isProblem(uuid: "nonexistent") == false)
    }

    @Test("clearProblemStatus removes failed status")
    func clearProblemStatus() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markFailed(uuid: "f1", filename: "f.jpg", mediaType: "photo", reason: "err")

        #expect(tracker.isProblem(uuid: "f1") == true)

        try tracker.clearProblemStatus(uuid: "f1")

        #expect(tracker.isProblem(uuid: "f1") == false)
    }

    @Test("markImported overwrites failed status on success")
    func markImportedOverwritesFailed() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // First fail
        try tracker.markFailed(uuid: "retry-1", filename: "r.jpg", mediaType: "photo", reason: "first attempt failed")
        #expect(tracker.isProblem(uuid: "retry-1") == true)

        // Then succeed
        try tracker.markImported(
            uuid: "retry-1",
            immichID: "immich-123",
            filename: "r.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        // Should no longer be a problem
        #expect(tracker.isProblem(uuid: "retry-1") == false)
        #expect(tracker.isImported(uuid: "retry-1") == true)

        // Problem stats should not include this asset
        let stats = tracker.getProblemStats()
        #expect(stats.failed == 0)
    }

    // MARK: - Favorites Sync Tests (Task Group 1)

    @Test("Migration adds is_favorite column to existing database")
    func migrationAddsFavoriteColumn() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import an asset first
        try tracker.markImported(
            uuid: "fav-test-1",
            immichID: "i1",
            filename: "photo.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        // Verify we can update favorite status (proves column exists)
        try tracker.updateFavoriteStatus(uuid: "fav-test-1", isFavorite: true)

        let status = tracker.getFavoriteStatus(uuid: "fav-test-1")
        #expect(status.isFavorite == true)
    }

    @Test("Migration adds favorite_modified_at column to existing database")
    func migrationAddsFavoriteModifiedAtColumn() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import an asset
        try tracker.markImported(
            uuid: "fav-test-2",
            immichID: "i2",
            filename: "photo2.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        // Update favorite status - should also set favorite_modified_at
        try tracker.updateFavoriteStatus(uuid: "fav-test-2", isFavorite: true)

        let status = tracker.getFavoriteStatus(uuid: "fav-test-2")
        #expect(status.modifiedAt != nil)
    }

    @Test("is_favorite defaults to NULL for existing rows")
    func favoriteDefaultsToNull() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import an asset without setting favorite status
        try tracker.markImported(
            uuid: "fav-test-3",
            immichID: "i3",
            filename: "photo3.jpg",
            fileSize: 1000,
            mediaType: "photo"
        )

        // Get status - should be nil since never set
        let status = tracker.getFavoriteStatus(uuid: "fav-test-3")
        #expect(status.isFavorite == nil)
        #expect(status.modifiedAt == nil)
    }

    @Test("Index creation on is_favorite column enables efficient queries")
    func favoriteIndexCreation() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import multiple assets with different favorite states
        try tracker.markImported(uuid: "fav-1", immichID: "i1", filename: "a.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "fav-2", immichID: "i2", filename: "b.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "fav-3", immichID: "i3", filename: "c.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "unfav-1", immichID: "i4", filename: "d.jpg", fileSize: 100, mediaType: "photo")

        // Set some as favorites
        try tracker.updateFavoriteStatus(uuid: "fav-1", isFavorite: true)
        try tracker.updateFavoriteStatus(uuid: "fav-2", isFavorite: true)
        try tracker.updateFavoriteStatus(uuid: "fav-3", isFavorite: true)
        try tracker.updateFavoriteStatus(uuid: "unfav-1", isFavorite: false)

        // Query assets with tracked favorites (proves index works for queries)
        let trackedFavorites = tracker.getAssetsWithTrackedFavorites()
        #expect(trackedFavorites.count == 4)

        // Verify we can find favorites
        let favorites = trackedFavorites.filter { $0.isFavorite == true }
        #expect(favorites.count == 3)
    }

    @Test("updateFavoriteStatus updates both columns correctly")
    func updateFavoriteStatus() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markImported(uuid: "update-fav", immichID: "i1", filename: "x.jpg", fileSize: 100, mediaType: "photo")

        // Initially nil
        let initial = tracker.getFavoriteStatus(uuid: "update-fav")
        #expect(initial.isFavorite == nil)

        // Set to true
        try tracker.updateFavoriteStatus(uuid: "update-fav", isFavorite: true)
        let afterTrue = tracker.getFavoriteStatus(uuid: "update-fav")
        #expect(afterTrue.isFavorite == true)
        #expect(afterTrue.modifiedAt != nil)

        // Set to false
        try tracker.updateFavoriteStatus(uuid: "update-fav", isFavorite: false)
        let afterFalse = tracker.getFavoriteStatus(uuid: "update-fav")
        #expect(afterFalse.isFavorite == false)
        #expect(afterFalse.modifiedAt != nil)
    }

    @Test("getFavoriteStatus returns correct tuple")
    func getFavoriteStatus() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        try tracker.markImported(uuid: "get-fav", immichID: "i1", filename: "x.jpg", fileSize: 100, mediaType: "photo")

        // Before setting
        let beforeStatus = tracker.getFavoriteStatus(uuid: "get-fav")
        #expect(beforeStatus.isFavorite == nil)
        #expect(beforeStatus.modifiedAt == nil)

        // After setting
        try tracker.updateFavoriteStatus(uuid: "get-fav", isFavorite: true)
        let afterStatus = tracker.getFavoriteStatus(uuid: "get-fav")
        #expect(afterStatus.isFavorite == true)
        #expect(afterStatus.modifiedAt != nil)

        // Non-existent UUID
        let nonExistent = tracker.getFavoriteStatus(uuid: "does-not-exist")
        #expect(nonExistent.isFavorite == nil)
        #expect(nonExistent.modifiedAt == nil)
    }

    @Test("getAssetsWithTrackedFavorites returns correct data")
    func getAssetsWithTrackedFavorites() throws {
        let (tracker, dbPath) = try createTestTracker()
        defer { cleanup(dbPath) }

        // Import assets - some with tracked favorites, some without
        try tracker.markImported(uuid: "tracked-1", immichID: "i1", filename: "a.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "tracked-2", immichID: "i2", filename: "b.jpg", fileSize: 100, mediaType: "photo")
        try tracker.markImported(uuid: "untracked", immichID: "i3", filename: "c.jpg", fileSize: 100, mediaType: "photo")

        // Set favorite status for some
        try tracker.updateFavoriteStatus(uuid: "tracked-1", isFavorite: true)
        try tracker.updateFavoriteStatus(uuid: "tracked-2", isFavorite: false)
        // Leave "untracked" without favorite status

        let tracked = tracker.getAssetsWithTrackedFavorites()
        #expect(tracked.count == 2)  // Only assets where is_favorite IS NOT NULL

        // Verify data structure
        let trackedOne = tracked.first { $0.uuid == "tracked-1" }
        #expect(trackedOne != nil)
        #expect(trackedOne?.immichId == "i1")
        #expect(trackedOne?.isFavorite == true)
        #expect(trackedOne?.modifiedAt != nil)

        let trackedTwo = tracked.first { $0.uuid == "tracked-2" }
        #expect(trackedTwo != nil)
        #expect(trackedTwo?.immichId == "i2")
        #expect(trackedTwo?.isFavorite == false)
    }
}
