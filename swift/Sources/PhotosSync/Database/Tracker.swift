import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Tracks imported assets - shares SQLite DB with Python code
/// Thread-safe via serial dispatch queue
class Tracker {
    private var db: OpaquePointer?
    private let dbPath: URL
    private let queue = DispatchQueue(label: "tracker.db.queue")
    
    init(dbPath: URL) throws {
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
            CREATE INDEX IF NOT EXISTS idx_archived ON imported_assets(archived);
        """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw TrackerError.execFailed(error)
        }
    }
    
    func isImported(uuid: String) -> Bool {
        let sql = "SELECT 1 FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, uuid, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    
    func getImportedUUIDs() -> Set<String> {
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
    
    func markImported(
        uuid: String,
        immichID: String?,
        filename: String,
        fileSize: Int64,
        mediaType: String
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets 
                (icloud_uuid, immich_id, filename, file_size, media_type, imported_at)
                VALUES (?, ?, ?, ?, ?, datetime('now'))
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
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    func getStats() -> (total: Int, photos: Int, videos: Int, totalBytes: Int64) {
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
    
    func getImmichIDForUUID(_ uuid: String) -> String? {
        let sql = "SELECT immich_id FROM imported_assets WHERE icloud_uuid = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, uuid, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) {
            return String(cString: cString)
        }
        return nil
    }
    
    private func querySingleInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return nil
    }
    
    private func querySingleInt64(_ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }
    
    /// Mark an asset as archived (deleted from Photos, kept in Immich)
    func markArchived(uuid: String) throws {
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
    func isArchived(uuid: String) -> Bool {
        let sql = "SELECT archived FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, uuid, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }
    
    /// Get all non-archived imported UUIDs (for import comparison)
    func getActiveImportedUUIDs() -> Set<String> {
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
    
    /// Remove an asset from tracking (when deleted from both Photos and Immich)
    func removeAsset(uuid: String) throws {
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
}

enum TrackerError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
