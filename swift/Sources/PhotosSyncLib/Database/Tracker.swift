import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Tracks imported assets - shares SQLite DB with Python code
/// Thread-safe via serial dispatch queue
public final class Tracker: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbPath: URL
    private let queue = DispatchQueue(label: "tracker.db.queue")
    
    public init(dbPath: URL) throws {
        self.dbPath = dbPath
        
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            throw TrackerError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        
        // Enable WAL mode for better concurrent read performance
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, &errMsg)
        
        try createTables()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func createTables() throws {
        // Only create basic table structure - indexes for new columns handled in migrations
        let sql = """
            CREATE TABLE IF NOT EXISTS imported_assets (
                icloud_uuid TEXT PRIMARY KEY,
                immich_id TEXT,
                filename TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                media_type TEXT NOT NULL,
                imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                archived INTEGER DEFAULT 0
            );
            
            CREATE INDEX IF NOT EXISTS idx_imported_at ON imported_assets(imported_at);
            CREATE INDEX IF NOT EXISTS idx_media_type ON imported_assets(media_type);
            CREATE INDEX IF NOT EXISTS idx_immich_id ON imported_assets(immich_id);
        """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw TrackerError.execFailed(error)
        }
        
        // Run migrations to add columns/indexes for existing databases
        try runMigrations()
    }
    
    private func runMigrations() throws {
        // SQLite doesn't support IF NOT EXISTS for ALTER TABLE, so we check column existence
        let columns = getColumnNames(table: "imported_assets")
        var errMsg: UnsafeMutablePointer<CChar>?
        
        // Migration 0: Add archived column (was in Swift schema but not Python-created DBs)
        if !columns.contains("archived") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN archived INTEGER DEFAULT 0"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                throw TrackerError.execFailed("Migration failed (archived): \(error)")
            }
            // Create index for archived column
            let indexSql = "CREATE INDEX IF NOT EXISTS idx_archived ON imported_assets(archived)"
            sqlite3_exec(db, indexSql, nil, nil, &errMsg)
            sqlite3_free(errMsg)
            errMsg = nil
        }
        
        // Migration 1: Add Live Photo columns
        // Use DEFAULT NULL so existing rows have unknown status (needing verification)
        if !columns.contains("is_live_photo") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN is_live_photo INTEGER DEFAULT NULL"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                throw TrackerError.execFailed("Migration failed (is_live_photo): \(error)")
            }
        }
        
        if !columns.contains("motion_video_immich_id") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN motion_video_immich_id TEXT"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                throw TrackerError.execFailed("Migration failed (motion_video_immich_id): \(error)")
            }
        }
        
        // Create index for Live Photo queries
        let indexSql = "CREATE INDEX IF NOT EXISTS idx_is_live_photo ON imported_assets(is_live_photo)"
        if sqlite3_exec(db, indexSql, nil, nil, &errMsg) != SQLITE_OK {
            // Index creation failure is non-fatal
            sqlite3_free(errMsg)
        }
    }
    
    private func getColumnNames(table: String) -> Set<String> {
        var columns = Set<String>()
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return columns
        }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {  // Column 1 is 'name'
                columns.insert(String(cString: cString))
            }
        }
        
        return columns
    }
    
    public func isImported(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT 1 FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }
    
    public func getImportedUUIDs() -> Set<String> {
        queue.sync {
            var uuids = Set<String>()
            let sql = "SELECT icloud_uuid FROM imported_assets"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return uuids
            }
            defer { sqlite3_finalize(stmt) }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    uuids.insert(String(cString: cString))
                }
            }
            
            return uuids
        }
    }
    
    public func markImported(
        uuid: String,
        immichID: String?,
        filename: String,
        fileSize: Int64,
        mediaType: String,
        isLivePhoto: Bool = false,
        motionVideoImmichID: String? = nil
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets 
                (icloud_uuid, immich_id, filename, file_size, media_type, imported_at, is_live_photo, motion_video_immich_id)
                VALUES (?, ?, ?, ?, ?, datetime('now'), ?, ?)
            """
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            if let immichID = immichID {
                sqlite3_bind_text(stmt, 2, immichID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, fileSize)
            sqlite3_bind_text(stmt, 5, mediaType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, isLivePhoto ? 1 : 0)
            if let motionVideoImmichID = motionVideoImmichID {
                sqlite3_bind_text(stmt, 7, motionVideoImmichID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    public func getStats() -> (total: Int, photos: Int, videos: Int, totalBytes: Int64) {
        var total = 0
        var photos = 0
        var videos = 0
        var totalBytes: Int64 = 0
        
        // Total count
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets") {
            total = count
        }
        
        // Photos count
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE media_type = 'photo'") {
            photos = count
        }
        
        // Videos count
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE media_type = 'video'") {
            videos = count
        }
        
        // Total size
        if let size = querySingleInt64("SELECT SUM(file_size) FROM imported_assets") {
            totalBytes = size
        }
        
        return (total, photos, videos, totalBytes)
    }
    
    public func getImmichIDForUUID(_ uuid: String) -> String? {
        queue.sync {
            let sql = "SELECT immich_id FROM imported_assets WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) {
                return String(cString: cString)
            }
            return nil
        }
    }
    
    private func querySingleInt(_ sql: String) -> Int? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return nil
        }
    }
    
    private func querySingleInt64(_ sql: String) -> Int64? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int64(stmt, 0)
            }
            return nil
        }
    }
    
    /// Mark an asset as archived (deleted from Photos, kept in Immich)
    public func markArchived(uuid: String) throws {
        try queue.sync {
            let sql = "UPDATE imported_assets SET archived = 1 WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    /// Check if an asset is archived
    public func isArchived(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT archived FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int(stmt, 0) == 1
            }
            return false
        }
    }
    
    /// Get all non-archived imported UUIDs (for import comparison)
    public func getActiveImportedUUIDs() -> Set<String> {
        queue.sync {
            var uuids = Set<String>()
            let sql = "SELECT icloud_uuid FROM imported_assets WHERE archived = 0 OR archived IS NULL"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return uuids
            }
            defer { sqlite3_finalize(stmt) }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    uuids.insert(String(cString: cString))
                }
            }
            
            return uuids
        }
    }
    
    /// Remove an asset from tracking (when deleted from both Photos and Immich)
    public func removeAsset(uuid: String) throws {
        try queue.sync {
            let sql = "DELETE FROM imported_assets WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    // MARK: - Live Photo Support
    
    /// Get the motion video Immich ID for a Live Photo
    public func getMotionVideoImmichID(uuid: String) -> String? {
        queue.sync {
            let sql = "SELECT motion_video_immich_id FROM imported_assets WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) {
                return String(cString: cString)
            }
            return nil
        }
    }
    
    /// Check if an asset is a Live Photo
    public func isLivePhoto(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT is_live_photo FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqlite3_column_int(stmt, 0) == 1
            }
            return false
        }
    }
    
    /// Check if a Live Photo has its motion video backed up
    public func hasMotionVideoBackup(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT motion_video_immich_id FROM imported_assets WHERE icloud_uuid = ? AND is_live_photo = 1"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                // Check if motion_video_immich_id is not NULL
                return sqlite3_column_type(stmt, 0) != SQLITE_NULL
            }
            return false
        }
    }
    
    /// Info about a Live Photo needing repair
    public struct LivePhotoRepairInfo {
        public let uuid: String
        public let immichID: String?
        public let filename: String
    }
    
    /// Get Live Photos that were imported without their motion video (need repair)
    /// These are assets where is_live_photo = 1 but motion_video_immich_id IS NULL
    /// Also includes old imports where is_live_photo is NULL (unknown status)
    public func getLivePhotosNeedingRepair() -> [LivePhotoRepairInfo] {
        queue.sync {
            var results: [LivePhotoRepairInfo] = []
            
            // Find assets that are known Live Photos without motion video backup
            // OR assets with unknown Live Photo status (pre-migration imports)
            let sql = """
                SELECT icloud_uuid, immich_id, filename FROM imported_assets 
                WHERE (is_live_photo = 1 AND motion_video_immich_id IS NULL)
                   OR is_live_photo IS NULL
                ORDER BY imported_at ASC
            """
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let uuidCStr = sqlite3_column_text(stmt, 0) else { continue }
                let uuid = String(cString: uuidCStr)
                
                let immichID: String?
                if let immichCStr = sqlite3_column_text(stmt, 1) {
                    immichID = String(cString: immichCStr)
                } else {
                    immichID = nil
                }
                
                let filename: String
                if let filenameCStr = sqlite3_column_text(stmt, 2) {
                    filename = String(cString: filenameCStr)
                } else {
                    filename = ""
                }
                
                results.append(LivePhotoRepairInfo(uuid: uuid, immichID: immichID, filename: filename))
            }
            
            return results
        }
    }
    
    /// Update an existing asset to mark it as a Live Photo with motion video
    public func updateLivePhotoInfo(uuid: String, isLivePhoto: Bool, motionVideoImmichID: String?) throws {
        try queue.sync {
            let sql = "UPDATE imported_assets SET is_live_photo = ?, motion_video_immich_id = ? WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_int(stmt, 1, isLivePhoto ? 1 : 0)
            if let motionVideoImmichID = motionVideoImmichID {
                sqlite3_bind_text(stmt, 2, motionVideoImmichID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, uuid, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    /// Get count of Live Photos and those with motion video backed up
    public func getLivePhotoStats() -> (total: Int, withMotionVideo: Int, needingRepair: Int) {
        var total = 0
        var withMotionVideo = 0
        var needingRepair = 0
        
        // Total Live Photos
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_live_photo = 1") {
            total = count
        }
        
        // With motion video backup
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_live_photo = 1 AND motion_video_immich_id IS NOT NULL") {
            withMotionVideo = count
        }
        
        // Needing repair (known Live Photos without motion video + unknown status)
        if let count = querySingleInt("""
            SELECT COUNT(*) FROM imported_assets 
            WHERE (is_live_photo = 1 AND motion_video_immich_id IS NULL)
               OR is_live_photo IS NULL
        """) {
            needingRepair = count
        }
        
        return (total, withMotionVideo, needingRepair)
    }
}

public enum TrackerError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
