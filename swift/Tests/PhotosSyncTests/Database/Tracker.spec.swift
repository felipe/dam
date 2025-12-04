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
}
