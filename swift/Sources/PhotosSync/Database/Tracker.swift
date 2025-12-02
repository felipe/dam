import Foundation
import SQLite3

/// Tracks imported assets - shares SQLite DB with Python code
class Tracker {
    private var db: OpaquePointer?
    private let dbPath: URL
    
    init(dbPath: URL) throws {
        self.dbPath = dbPath
        
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            throw TrackerError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        
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
                imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
        
        sqlite3_bind_text(stmt, 1, uuid, -1, nil)
        if let immichID = immichID {
            sqlite3_bind_text(stmt, 2, immichID, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, filename, -1, nil)
        sqlite3_bind_int64(stmt, 4, fileSize)
        sqlite3_bind_text(stmt, 5, mediaType, -1, nil)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
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
}

enum TrackerError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
