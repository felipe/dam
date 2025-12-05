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
        var indexSql = "CREATE INDEX IF NOT EXISTS idx_is_live_photo ON imported_assets(is_live_photo)"
        if sqlite3_exec(db, indexSql, nil, nil, &errMsg) != SQLITE_OK {
            // Index creation failure is non-fatal
            sqlite3_free(errMsg)
            errMsg = nil
        }
        
        // Migration 2: Add subtype columns for special media tracking
        let subtypeColumns = [
            "is_portrait",
            "is_hdr", 
            "is_panorama",
            "is_screenshot",
            "is_cinematic",
            "is_slomo",
            "is_timelapse",
            "is_spatial_video",
            "is_proraw",
            "has_paired_video"
        ]
        
        // Re-fetch columns after previous migrations
        let currentColumns = getColumnNames(table: "imported_assets")
        
        for column in subtypeColumns {
            if !currentColumns.contains(column) {
                let sql = "ALTER TABLE imported_assets ADD COLUMN \(column) INTEGER DEFAULT NULL"
                if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                    let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                    sqlite3_free(errMsg)
                    errMsg = nil
                    // Log but don't fail - column might already exist
                    print("Migration warning (\(column)): \(error)")
                }
            }
        }
        
        // Create index for has_paired_video queries
        indexSql = "CREATE INDEX IF NOT EXISTS idx_has_paired_video ON imported_assets(has_paired_video)"
        sqlite3_exec(db, indexSql, nil, nil, &errMsg)
        sqlite3_free(errMsg)
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
    
    /// Asset subtype information for tracking
    public struct AssetSubtypes: Sendable {
        public let isLivePhoto: Bool
        public let isPortrait: Bool
        public let isHDR: Bool
        public let isPanorama: Bool
        public let isScreenshot: Bool
        public let isCinematic: Bool
        public let isSlomo: Bool
        public let isTimelapse: Bool
        public let isSpatialVideo: Bool
        public let isProRAW: Bool
        public let hasPairedVideo: Bool
        
        public init(
            isLivePhoto: Bool = false,
            isPortrait: Bool = false,
            isHDR: Bool = false,
            isPanorama: Bool = false,
            isScreenshot: Bool = false,
            isCinematic: Bool = false,
            isSlomo: Bool = false,
            isTimelapse: Bool = false,
            isSpatialVideo: Bool = false,
            isProRAW: Bool = false,
            hasPairedVideo: Bool = false
        ) {
            self.isLivePhoto = isLivePhoto
            self.isPortrait = isPortrait
            self.isHDR = isHDR
            self.isPanorama = isPanorama
            self.isScreenshot = isScreenshot
            self.isCinematic = isCinematic
            self.isSlomo = isSlomo
            self.isTimelapse = isTimelapse
            self.isSpatialVideo = isSpatialVideo
            self.isProRAW = isProRAW
            self.hasPairedVideo = hasPairedVideo
        }
        
        /// Create default subtypes (no special flags)
        public static let none = AssetSubtypes()
    }
    
    public func markImported(
        uuid: String,
        immichID: String?,
        filename: String,
        fileSize: Int64,
        mediaType: String,
        subtypes: AssetSubtypes = .none,
        motionVideoImmichID: String? = nil
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets 
                (icloud_uuid, immich_id, filename, file_size, media_type, imported_at,
                 is_live_photo, is_portrait, is_hdr, is_panorama, is_screenshot,
                 is_cinematic, is_slomo, is_timelapse, is_spatial_video, is_proraw,
                 has_paired_video, motion_video_immich_id)
                VALUES (?, ?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            
            // Bind subtype flags
            sqlite3_bind_int(stmt, 6, subtypes.isLivePhoto ? 1 : 0)
            sqlite3_bind_int(stmt, 7, subtypes.isPortrait ? 1 : 0)
            sqlite3_bind_int(stmt, 8, subtypes.isHDR ? 1 : 0)
            sqlite3_bind_int(stmt, 9, subtypes.isPanorama ? 1 : 0)
            sqlite3_bind_int(stmt, 10, subtypes.isScreenshot ? 1 : 0)
            sqlite3_bind_int(stmt, 11, subtypes.isCinematic ? 1 : 0)
            sqlite3_bind_int(stmt, 12, subtypes.isSlomo ? 1 : 0)
            sqlite3_bind_int(stmt, 13, subtypes.isTimelapse ? 1 : 0)
            sqlite3_bind_int(stmt, 14, subtypes.isSpatialVideo ? 1 : 0)
            sqlite3_bind_int(stmt, 15, subtypes.isProRAW ? 1 : 0)
            sqlite3_bind_int(stmt, 16, subtypes.hasPairedVideo ? 1 : 0)
            
            if let motionVideoImmichID = motionVideoImmichID {
                sqlite3_bind_text(stmt, 17, motionVideoImmichID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 17)
            }
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    
    /// Backward-compatible version for Live Photo imports
    public func markImportedLivePhoto(
        uuid: String,
        immichID: String?,
        filename: String,
        fileSize: Int64,
        mediaType: String,
        isLivePhoto: Bool,
        motionVideoImmichID: String?
    ) throws {
        let subtypes = AssetSubtypes(isLivePhoto: isLivePhoto, hasPairedVideo: isLivePhoto)
        try markImported(
            uuid: uuid,
            immichID: immichID,
            filename: filename,
            fileSize: fileSize,
            mediaType: mediaType,
            subtypes: subtypes,
            motionVideoImmichID: motionVideoImmichID
        )
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
    
    /// Check if an asset with paired video has its motion video backed up
    /// Checks both is_live_photo and has_paired_video columns
    public func hasMotionVideoBackup(uuid: String) -> Bool {
        queue.sync {
            let sql = """
                SELECT motion_video_immich_id FROM imported_assets 
                WHERE icloud_uuid = ? AND (is_live_photo = 1 OR has_paired_video = 1)
            """
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
    
    /// Check if an asset has a paired video resource (from tracker data)
    public func hasPairedVideo(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT has_paired_video FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
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
    
    /// Info about an asset needing paired video repair
    public struct PairedVideoRepairInfo: Sendable {
        public let uuid: String
        public let immichID: String?
        public let filename: String
    }
    
    /// Alias for backward compatibility
    public typealias LivePhotoRepairInfo = PairedVideoRepairInfo
    
    /// Get assets with paired video that were imported without their motion video (need repair)
    /// This includes:
    /// - Assets where has_paired_video = 1 but motion_video_immich_id IS NULL
    /// - Assets where is_live_photo = 1 but motion_video_immich_id IS NULL
    /// - Old imports where is_live_photo IS NULL (unknown status, pre-migration)
    public func getAssetsNeedingPairedVideoRepair() -> [PairedVideoRepairInfo] {
        queue.sync {
            var results: [PairedVideoRepairInfo] = []
            
            let sql = """
                SELECT icloud_uuid, immich_id, filename FROM imported_assets 
                WHERE ((has_paired_video = 1 OR is_live_photo = 1) AND motion_video_immich_id IS NULL)
                   OR (is_live_photo IS NULL AND has_paired_video IS NULL)
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
                
                results.append(PairedVideoRepairInfo(uuid: uuid, immichID: immichID, filename: filename))
            }
            
            return results
        }
    }
    
    /// Alias for backward compatibility
    public func getLivePhotosNeedingRepair() -> [PairedVideoRepairInfo] {
        return getAssetsNeedingPairedVideoRepair()
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
    
    /// Get count of assets with paired video and their backup status
    public func getPairedVideoStats() -> (total: Int, withMotionVideo: Int, needingRepair: Int) {
        var total = 0
        var withMotionVideo = 0
        var needingRepair = 0
        
        // Total with paired video (includes Live Photos)
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE has_paired_video = 1 OR is_live_photo = 1") {
            total = count
        }
        
        // With motion video backup
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE (has_paired_video = 1 OR is_live_photo = 1) AND motion_video_immich_id IS NOT NULL") {
            withMotionVideo = count
        }
        
        // Needing repair
        if let count = querySingleInt("""
            SELECT COUNT(*) FROM imported_assets 
            WHERE ((has_paired_video = 1 OR is_live_photo = 1) AND motion_video_immich_id IS NULL)
               OR (is_live_photo IS NULL AND has_paired_video IS NULL)
        """) {
            needingRepair = count
        }
        
        return (total, withMotionVideo, needingRepair)
    }
    
    /// Get subtype statistics
    public func getSubtypeStats() -> (portrait: Int, hdr: Int, panorama: Int, screenshot: Int, cinematic: Int, slomo: Int, timelapse: Int, spatialVideo: Int, proraw: Int) {
        return (
            portrait: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_portrait = 1") ?? 0,
            hdr: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_hdr = 1") ?? 0,
            panorama: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_panorama = 1") ?? 0,
            screenshot: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_screenshot = 1") ?? 0,
            cinematic: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_cinematic = 1") ?? 0,
            slomo: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_slomo = 1") ?? 0,
            timelapse: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_timelapse = 1") ?? 0,
            spatialVideo: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_spatial_video = 1") ?? 0,
            proraw: querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_proraw = 1") ?? 0
        )
    }
    
    /// Update an asset's paired video info
    public func updatePairedVideoInfo(uuid: String, hasPairedVideo: Bool, motionVideoImmichID: String?) throws {
        try queue.sync {
            let sql = "UPDATE imported_assets SET has_paired_video = ?, motion_video_immich_id = ? WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_int(stmt, 1, hasPairedVideo ? 1 : 0)
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
}

public enum TrackerError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
