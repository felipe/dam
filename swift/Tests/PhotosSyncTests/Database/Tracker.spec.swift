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
}
