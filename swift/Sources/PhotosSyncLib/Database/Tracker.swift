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
            "has_paired_video",
            "cinematic_sidecars"  // JSON array of sidecar filenames
        ]

        // Re-fetch columns after previous migrations
        let currentColumns = getColumnNames(table: "imported_assets")

        for column in subtypeColumns {
            if !currentColumns.contains(column) {
                let colType = column == "cinematic_sidecars" ? "TEXT" : "INTEGER DEFAULT NULL"
                let sql = "ALTER TABLE imported_assets ADD COLUMN \(column) \(colType)"
                if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                    let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                    sqlite3_free(errMsg)
                    errMsg = nil
                    // Log but don't fail - column might already exist
                    print("Migration warning (\(column)): \(error)")
                }
            }
        }

        // Create indexes for common queries
        indexSql = "CREATE INDEX IF NOT EXISTS idx_has_paired_video ON imported_assets(has_paired_video)"
        sqlite3_exec(db, indexSql, nil, nil, &errMsg)
        sqlite3_free(errMsg)
        errMsg = nil

        indexSql = "CREATE INDEX IF NOT EXISTS idx_is_cinematic ON imported_assets(is_cinematic)"
        sqlite3_exec(db, indexSql, nil, nil, &errMsg)
        sqlite3_free(errMsg)
        errMsg = nil

        // Migration 3: Add problem asset tracking columns
        let problemColumns = getColumnNames(table: "imported_assets")

        if !problemColumns.contains("status") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN status TEXT DEFAULT 'imported'"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                errMsg = nil
                print("Migration warning (status): \(error)")
            }
        }

        if !problemColumns.contains("error_reason") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN error_reason TEXT"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                errMsg = nil
                print("Migration warning (error_reason): \(error)")
            }
        }

        if !problemColumns.contains("asset_created_at") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN asset_created_at TIMESTAMP"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                errMsg = nil
                print("Migration warning (asset_created_at): \(error)")
            }
        }

        // Create index for status queries
        indexSql = "CREATE INDEX IF NOT EXISTS idx_status ON imported_assets(status)"
        sqlite3_exec(db, indexSql, nil, nil, &errMsg)
        sqlite3_free(errMsg)
        errMsg = nil

        // Migration 4: Add backup tables
        try runBackupMigrations()

        // Migration 5: Add favorites sync columns
        try runFavoritesMigrations()
    }

    private func runBackupMigrations() throws {
        var errMsg: UnsafeMutablePointer<CChar>?

        // Create backup_destinations table
        let destinationsSql = """
            CREATE TABLE IF NOT EXISTS backup_destinations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                type TEXT NOT NULL,
                bucket_name TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                last_backup_at TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_backup_dest_name ON backup_destinations(name);
        """

        if sqlite3_exec(db, destinationsSql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            errMsg = nil
            print("Migration warning (backup_destinations): \(error)")
        }

        // Create backup_jobs table
        let jobsSql = """
            CREATE TABLE IF NOT EXISTS backup_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                destination_id INTEGER NOT NULL,
                source_path TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'PENDING',
                bytes_total INTEGER DEFAULT 0,
                bytes_transferred INTEGER DEFAULT 0,
                files_total INTEGER DEFAULT 0,
                files_transferred INTEGER DEFAULT 0,
                transfer_speed INTEGER DEFAULT 0,
                started_at TIMESTAMP,
                completed_at TIMESTAMP,
                last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                error_message TEXT,
                retry_count INTEGER DEFAULT 0,
                priority INTEGER DEFAULT 0,
                FOREIGN KEY (destination_id) REFERENCES backup_destinations(id)
            );
            CREATE INDEX IF NOT EXISTS idx_backup_jobs_status ON backup_jobs(status);
            CREATE INDEX IF NOT EXISTS idx_backup_jobs_dest ON backup_jobs(destination_id);
            CREATE INDEX IF NOT EXISTS idx_backup_jobs_last_update ON backup_jobs(last_update);
        """

        if sqlite3_exec(db, jobsSql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            print("Migration warning (backup_jobs): \(error)")
        }
    }

    /// Migration 5: Add favorites sync columns for bidirectional favorites sync
    private func runFavoritesMigrations() throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let columns = getColumnNames(table: "imported_assets")

        // Add is_favorite column (INTEGER to store Bool: 0=false, 1=true, NULL=unknown)
        if !columns.contains("is_favorite") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN is_favorite INTEGER DEFAULT NULL"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                errMsg = nil
                print("Migration warning (is_favorite): \(error)")
            }
        }

        // Add favorite_modified_at column to track when favorite status last changed
        if !columns.contains("favorite_modified_at") {
            let sql = "ALTER TABLE imported_assets ADD COLUMN favorite_modified_at TIMESTAMP DEFAULT NULL"
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                errMsg = nil
                print("Migration warning (favorite_modified_at): \(error)")
            }
        }

        // Create index on is_favorite for efficient favorite queries
        let indexSql = "CREATE INDEX IF NOT EXISTS idx_is_favorite ON imported_assets(is_favorite)"
        if sqlite3_exec(db, indexSql, nil, nil, &errMsg) != SQLITE_OK {
            // Index creation failure is non-fatal
            sqlite3_free(errMsg)
            errMsg = nil
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
        motionVideoImmichID: String? = nil,
        cinematicSidecars: [String]? = nil
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets
                (icloud_uuid, immich_id, filename, file_size, media_type, imported_at, status, error_reason,
                 is_live_photo, is_portrait, is_hdr, is_panorama, is_screenshot,
                 is_cinematic, is_slomo, is_timelapse, is_spatial_video, is_proraw,
                 has_paired_video, motion_video_immich_id, cinematic_sidecars)
                VALUES (?, ?, ?, ?, ?, datetime('now'), 'imported', NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

            if let sidecars = cinematicSidecars, !sidecars.isEmpty {
                // Store as JSON array
                if let jsonData = try? JSONSerialization.data(withJSONObject: sidecars),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 18, jsonString, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 18)
                }
            } else {
                sqlite3_bind_null(stmt, 18)
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

    /// Update all subtype flags for an asset (preserves other data like immich_id, filename, etc.)
    public func updateSubtypes(uuid: String, subtypes: AssetSubtypes) throws {
        try queue.sync {
            let sql = """
                UPDATE imported_assets SET
                    is_live_photo = ?,
                    is_portrait = ?,
                    is_hdr = ?,
                    is_panorama = ?,
                    is_screenshot = ?,
                    is_cinematic = ?,
                    is_slomo = ?,
                    is_timelapse = ?,
                    is_spatial_video = ?,
                    is_proraw = ?,
                    has_paired_video = ?
                WHERE icloud_uuid = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, subtypes.isLivePhoto ? 1 : 0)
            sqlite3_bind_int(stmt, 2, subtypes.isPortrait ? 1 : 0)
            sqlite3_bind_int(stmt, 3, subtypes.isHDR ? 1 : 0)
            sqlite3_bind_int(stmt, 4, subtypes.isPanorama ? 1 : 0)
            sqlite3_bind_int(stmt, 5, subtypes.isScreenshot ? 1 : 0)
            sqlite3_bind_int(stmt, 6, subtypes.isCinematic ? 1 : 0)
            sqlite3_bind_int(stmt, 7, subtypes.isSlomo ? 1 : 0)
            sqlite3_bind_int(stmt, 8, subtypes.isTimelapse ? 1 : 0)
            sqlite3_bind_int(stmt, 9, subtypes.isSpatialVideo ? 1 : 0)
            sqlite3_bind_int(stmt, 10, subtypes.isProRAW ? 1 : 0)
            sqlite3_bind_int(stmt, 11, subtypes.hasPairedVideo ? 1 : 0)
            sqlite3_bind_text(stmt, 12, uuid, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Cinematic Video Support

    /// Check if an asset is a Cinematic video
    public func isCinematic(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT is_cinematic FROM imported_assets WHERE icloud_uuid = ? LIMIT 1"
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

    /// Get the sidecar filenames for a Cinematic video
    public func getCinematicSidecars(uuid: String) -> [String] {
        queue.sync {
            let sql = "SELECT cinematic_sidecars FROM imported_assets WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_ROW,
               let cString = sqlite3_column_text(stmt, 0) {
                let jsonString = String(cString: cString)
                if let data = jsonString.data(using: .utf8),
                   let sidecars = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    return sidecars
                }
            }
            return []
        }
    }

    /// Update Cinematic info for an existing asset
    public func updateCinematicInfo(uuid: String, isCinematic: Bool, sidecars: [String]?) throws {
        try queue.sync {
            let sql = "UPDATE imported_assets SET is_cinematic = ?, cinematic_sidecars = ? WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isCinematic ? 1 : 0)
            if let sidecars = sidecars, !sidecars.isEmpty {
                if let jsonData = try? JSONSerialization.data(withJSONObject: sidecars),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 2, jsonString, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, uuid, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Info about a Cinematic video needing repair (imported without sidecars)
    public struct CinematicRepairInfo: Sendable {
        public let uuid: String
        public let immichID: String?
        public let filename: String
    }

    /// Get Cinematic videos that were imported without their sidecars
    public func getCinematicsNeedingRepair() -> [CinematicRepairInfo] {
        queue.sync {
            var results: [CinematicRepairInfo] = []

            // Find assets that are known Cinematic without sidecars
            // OR assets with unknown Cinematic status (pre-migration imports)
            let sql = """
                SELECT icloud_uuid, immich_id, filename FROM imported_assets
                WHERE (is_cinematic = 1 AND (cinematic_sidecars IS NULL OR cinematic_sidecars = '[]'))
                   OR (is_cinematic IS NULL AND media_type = 'video')
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

                results.append(CinematicRepairInfo(uuid: uuid, immichID: immichID, filename: filename))
            }

            return results
        }
    }

    /// Get count of Cinematic videos and those with sidecars backed up
    public func getCinematicStats() -> (total: Int, withSidecars: Int, needingRepair: Int) {
        var total = 0
        var withSidecars = 0
        var needingRepair = 0

        // Total Cinematic videos
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_cinematic = 1") {
            total = count
        }

        // With sidecars backup
        if let count = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE is_cinematic = 1 AND cinematic_sidecars IS NOT NULL AND cinematic_sidecars != '[]'") {
            withSidecars = count
        }

        // Needing repair (known Cinematic without sidecars + unknown status videos)
        if let count = querySingleInt("""
            SELECT COUNT(*) FROM imported_assets
            WHERE (is_cinematic = 1 AND (cinematic_sidecars IS NULL OR cinematic_sidecars = '[]'))
               OR (is_cinematic IS NULL AND media_type = 'video')
        """) {
            needingRepair = count
        }

        return (total, withSidecars, needingRepair)
    }
    // MARK: - Problem Asset Tracking

    /// Information about a problem asset (failed or skipped)
    public struct ProblemAsset: Sendable {
        public let uuid: String
        public let filename: String
        public let mediaType: String
        public let status: String        // "failed" or "skipped"
        public let reason: String
        public let createdAt: Date?      // When the asset was created in Photos
        public let recordedAt: Date      // When we recorded this problem

        public init(uuid: String, filename: String, mediaType: String, status: String, reason: String, createdAt: Date?, recordedAt: Date) {
            self.uuid = uuid
            self.filename = filename
            self.mediaType = mediaType
            self.status = status
            self.reason = reason
            self.createdAt = createdAt
            self.recordedAt = recordedAt
        }
    }

    /// Mark an asset as failed (couldn't import)
    public func markFailed(
        uuid: String,
        filename: String,
        mediaType: String,
        reason: String,
        createdAt: Date? = nil
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets
                (icloud_uuid, filename, file_size, media_type, imported_at, status, error_reason, asset_created_at)
                VALUES (?, ?, 0, ?, datetime('now'), 'failed', ?, ?)
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, mediaType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, reason, -1, SQLITE_TRANSIENT)

            if let createdAt = createdAt {
                let formatter = ISO8601DateFormatter()
                sqlite3_bind_text(stmt, 5, formatter.string(from: createdAt), -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Mark an asset as skipped (intentionally not imported)
    public func markSkipped(
        uuid: String,
        filename: String,
        mediaType: String,
        reason: String,
        createdAt: Date? = nil
    ) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO imported_assets
                (icloud_uuid, filename, file_size, media_type, imported_at, status, error_reason, asset_created_at)
                VALUES (?, ?, 0, ?, datetime('now'), 'skipped', ?, ?)
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, mediaType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, reason, -1, SQLITE_TRANSIENT)

            if let createdAt = createdAt {
                let formatter = ISO8601DateFormatter()
                sqlite3_bind_text(stmt, 5, formatter.string(from: createdAt), -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Get all problem assets (failed + skipped)
    public func getProblemAssets() -> [ProblemAsset] {
        queue.sync {
            var results: [ProblemAsset] = []

            let sql = """
                SELECT icloud_uuid, filename, media_type, status, error_reason, asset_created_at, imported_at
                FROM imported_assets
                WHERE status IN ('failed', 'skipped')
                ORDER BY imported_at DESC
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }

            let dateFormatter = ISO8601DateFormatter()

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let uuidCStr = sqlite3_column_text(stmt, 0) else { continue }
                let uuid = String(cString: uuidCStr)

                let filename = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let mediaType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "unknown"
                let status = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "failed"
                let reason = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""

                var createdAt: Date? = nil
                if let createdAtCStr = sqlite3_column_text(stmt, 5) {
                    createdAt = dateFormatter.date(from: String(cString: createdAtCStr))
                }

                var recordedAt = Date()
                if let recordedAtCStr = sqlite3_column_text(stmt, 6) {
                    // Parse SQLite datetime format
                    let sqlFormatter = DateFormatter()
                    sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    sqlFormatter.timeZone = TimeZone(identifier: "UTC")
                    if let parsed = sqlFormatter.date(from: String(cString: recordedAtCStr)) {
                        recordedAt = parsed
                    }
                }

                results.append(ProblemAsset(
                    uuid: uuid,
                    filename: filename,
                    mediaType: mediaType,
                    status: status,
                    reason: reason,
                    createdAt: createdAt,
                    recordedAt: recordedAt
                ))
            }

            return results
        }
    }

    /// Get only failed assets
    public func getFailedAssets() -> [ProblemAsset] {
        return getProblemAssets().filter { $0.status == "failed" }
    }

    /// Get only skipped assets
    public func getSkippedAssets() -> [ProblemAsset] {
        return getProblemAssets().filter { $0.status == "skipped" }
    }

    /// Get problem asset statistics
    public func getProblemStats() -> (failed: Int, skipped: Int) {
        let failed = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE status = 'failed'") ?? 0
        let skipped = querySingleInt("SELECT COUNT(*) FROM imported_assets WHERE status = 'skipped'") ?? 0
        return (failed, skipped)
    }

    /// Check if an asset is marked as a problem (failed or skipped)
    public func isProblem(uuid: String) -> Bool {
        queue.sync {
            let sql = "SELECT status FROM imported_assets WHERE icloud_uuid = ? AND status IN ('failed', 'skipped') LIMIT 1"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    /// Clear problem status for an asset (used before retry)
    public func clearProblemStatus(uuid: String) throws {
        try queue.sync {
            let sql = "DELETE FROM imported_assets WHERE icloud_uuid = ? AND status IN ('failed', 'skipped')"
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

    // MARK: - Favorites Sync Support

    /// Update the favorite status for an asset
    /// - Parameters:
    ///   - uuid: The iCloud UUID of the asset
    ///   - isFavorite: The new favorite status (true/false)
    public func updateFavoriteStatus(uuid: String, isFavorite: Bool) throws {
        try queue.sync {
            let sql = "UPDATE imported_assets SET is_favorite = ?, favorite_modified_at = datetime('now') WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
            sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Get the favorite status for an asset
    /// - Parameter uuid: The iCloud UUID of the asset
    /// - Returns: A tuple with (isFavorite: Bool?, modifiedAt: Date?) - nil values indicate no tracked status
    public func getFavoriteStatus(uuid: String) -> (isFavorite: Bool?, modifiedAt: Date?) {
        queue.sync {
            let sql = "SELECT is_favorite, favorite_modified_at FROM imported_assets WHERE icloud_uuid = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return (nil, nil)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_ROW {
                // Check if is_favorite is NULL
                var isFavorite: Bool? = nil
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                    isFavorite = sqlite3_column_int(stmt, 0) == 1
                }

                // Check if favorite_modified_at is NULL
                var modifiedAt: Date? = nil
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL,
                   let cStr = sqlite3_column_text(stmt, 1) {
                    let sqlFormatter = DateFormatter()
                    sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    sqlFormatter.timeZone = TimeZone(identifier: "UTC")
                    modifiedAt = sqlFormatter.date(from: String(cString: cStr))
                }

                return (isFavorite, modifiedAt)
            }
            return (nil, nil)
        }
    }

    /// Info about an asset with tracked favorite status
    public struct TrackedFavoriteInfo: Sendable {
        public let uuid: String
        public let immichId: String?
        public let isFavorite: Bool
        public let modifiedAt: Date?
    }

    /// Get all assets that have tracked favorite status (is_favorite IS NOT NULL)
    /// - Returns: List of assets with their UUID, Immich ID, favorite status, and modification timestamp
    public func getAssetsWithTrackedFavorites() -> [TrackedFavoriteInfo] {
        queue.sync {
            var results: [TrackedFavoriteInfo] = []

            let sql = """
                SELECT icloud_uuid, immich_id, is_favorite, favorite_modified_at
                FROM imported_assets
                WHERE is_favorite IS NOT NULL
                ORDER BY favorite_modified_at DESC
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }

            let sqlFormatter = DateFormatter()
            sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            sqlFormatter.timeZone = TimeZone(identifier: "UTC")

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let uuidCStr = sqlite3_column_text(stmt, 0) else { continue }
                let uuid = String(cString: uuidCStr)

                let immichId: String?
                if let immichCStr = sqlite3_column_text(stmt, 1) {
                    immichId = String(cString: immichCStr)
                } else {
                    immichId = nil
                }

                let isFavorite = sqlite3_column_int(stmt, 2) == 1

                var modifiedAt: Date? = nil
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                   let cStr = sqlite3_column_text(stmt, 3) {
                    modifiedAt = sqlFormatter.date(from: String(cString: cStr))
                }

                results.append(TrackedFavoriteInfo(
                    uuid: uuid,
                    immichId: immichId,
                    isFavorite: isFavorite,
                    modifiedAt: modifiedAt
                ))
            }

            return results
        }
    }

    // MARK: - Backup Destination Support

    /// Backup destination information
    public struct BackupDestination: Sendable {
        public let id: Int64
        public let name: String
        public let type: String
        public let bucketName: String
        public let remotePath: String
        public let createdAt: Date
        public let lastBackupAt: Date?

        public init(id: Int64, name: String, type: String, bucketName: String, remotePath: String, createdAt: Date, lastBackupAt: Date?) {
            self.id = id
            self.name = name
            self.type = type
            self.bucketName = bucketName
            self.remotePath = remotePath
            self.createdAt = createdAt
            self.lastBackupAt = lastBackupAt
        }
    }

    /// Create a new backup destination
    public func createBackupDestination(name: String, type: String, bucketName: String, remotePath: String) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO backup_destinations (name, type, bucket_name, remote_path, created_at)
                VALUES (?, ?, ?, ?, datetime('now'))
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, bucketName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, remotePath, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }

            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Get all backup destinations
    public func getBackupDestinations() -> [BackupDestination] {
        queue.sync {
            var results: [BackupDestination] = []

            let sql = """
                SELECT id, name, type, bucket_name, remote_path, created_at, last_backup_at
                FROM backup_destinations
                ORDER BY name
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }

            let sqlFormatter = DateFormatter()
            sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            sqlFormatter.timeZone = TimeZone(identifier: "UTC")

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let bucketName = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let remotePath = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""

                var createdAt = Date()
                if let createdAtCStr = sqlite3_column_text(stmt, 5) {
                    createdAt = sqlFormatter.date(from: String(cString: createdAtCStr)) ?? Date()
                }

                var lastBackupAt: Date? = nil
                if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                   let lastBackupCStr = sqlite3_column_text(stmt, 6) {
                    lastBackupAt = sqlFormatter.date(from: String(cString: lastBackupCStr))
                }

                results.append(BackupDestination(
                    id: id,
                    name: name,
                    type: type,
                    bucketName: bucketName,
                    remotePath: remotePath,
                    createdAt: createdAt,
                    lastBackupAt: lastBackupAt
                ))
            }

            return results
        }
    }

    /// Get a backup destination by name
    public func getBackupDestination(name: String) -> BackupDestination? {
        queue.sync {
            let sql = """
                SELECT id, name, type, bucket_name, remote_path, created_at, last_backup_at
                FROM backup_destinations
                WHERE name = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)

            let sqlFormatter = DateFormatter()
            sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            sqlFormatter.timeZone = TimeZone(identifier: "UTC")

            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let bucketName = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let remotePath = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""

                var createdAt = Date()
                if let createdAtCStr = sqlite3_column_text(stmt, 5) {
                    createdAt = sqlFormatter.date(from: String(cString: createdAtCStr)) ?? Date()
                }

                var lastBackupAt: Date? = nil
                if sqlite3_column_type(stmt, 6) != SQLITE_NULL,
                   let lastBackupCStr = sqlite3_column_text(stmt, 6) {
                    lastBackupAt = sqlFormatter.date(from: String(cString: lastBackupCStr))
                }

                return BackupDestination(
                    id: id,
                    name: name,
                    type: type,
                    bucketName: bucketName,
                    remotePath: remotePath,
                    createdAt: createdAt,
                    lastBackupAt: lastBackupAt
                )
            }

            return nil
        }
    }

    // MARK: - Backup Job Support

    /// Backup job status
    public enum BackupJobStatus: String, Sendable {
        case pending = "PENDING"
        case running = "RUNNING"
        case completed = "COMPLETED"
        case interrupted = "INTERRUPTED"
        case failed = "FAILED"
    }

    /// Backup job information
    public struct BackupJob: Sendable {
        public let id: Int64
        public let destinationId: Int64
        public let sourcePath: String
        public let status: BackupJobStatus
        public let bytesTotal: Int64
        public let bytesTransferred: Int64
        public let filesTotal: Int64
        public let filesTransferred: Int64
        public let transferSpeed: Int64
        public let startedAt: Date?
        public let completedAt: Date?
        public let lastUpdate: Date
        public let errorMessage: String?
        public let retryCount: Int
        public let priority: Int

        public init(
            id: Int64,
            destinationId: Int64,
            sourcePath: String,
            status: BackupJobStatus,
            bytesTotal: Int64,
            bytesTransferred: Int64,
            filesTotal: Int64,
            filesTransferred: Int64,
            transferSpeed: Int64,
            startedAt: Date?,
            completedAt: Date?,
            lastUpdate: Date,
            errorMessage: String?,
            retryCount: Int,
            priority: Int
        ) {
            self.id = id
            self.destinationId = destinationId
            self.sourcePath = sourcePath
            self.status = status
            self.bytesTotal = bytesTotal
            self.bytesTransferred = bytesTransferred
            self.filesTotal = filesTotal
            self.filesTransferred = filesTransferred
            self.transferSpeed = transferSpeed
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.lastUpdate = lastUpdate
            self.errorMessage = errorMessage
            self.retryCount = retryCount
            self.priority = priority
        }
    }

    /// Create a new backup job
    public func createBackupJob(destinationId: Int64, sourcePath: String, priority: Int) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO backup_jobs (destination_id, source_path, status, priority, last_update)
                VALUES (?, ?, 'PENDING', ?, datetime('now'))
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, destinationId)
            sqlite3_bind_text(stmt, 2, sourcePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(priority))

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }

            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Update a backup job's progress
    public func updateBackupJob(
        id: Int64,
        status: BackupJobStatus,
        bytesTotal: Int64,
        bytesTransferred: Int64,
        filesTotal: Int64,
        filesTransferred: Int64,
        transferSpeed: Int64,
        errorMessage: String? = nil
    ) throws {
        try queue.sync {
            var sql = """
                UPDATE backup_jobs SET
                    status = ?,
                    bytes_total = ?,
                    bytes_transferred = ?,
                    files_total = ?,
                    files_transferred = ?,
                    transfer_speed = ?,
                    last_update = datetime('now')
            """

            if status == .running {
                sql += ", started_at = COALESCE(started_at, datetime('now'))"
            }

            if let _ = errorMessage {
                sql += ", error_message = ?"
            }

            sql += " WHERE id = ?"

            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var paramIndex: Int32 = 1
            sqlite3_bind_text(stmt, paramIndex, status.rawValue, -1, SQLITE_TRANSIENT)
            paramIndex += 1
            sqlite3_bind_int64(stmt, paramIndex, bytesTotal)
            paramIndex += 1
            sqlite3_bind_int64(stmt, paramIndex, bytesTransferred)
            paramIndex += 1
            sqlite3_bind_int64(stmt, paramIndex, filesTotal)
            paramIndex += 1
            sqlite3_bind_int64(stmt, paramIndex, filesTransferred)
            paramIndex += 1
            sqlite3_bind_int64(stmt, paramIndex, transferSpeed)
            paramIndex += 1

            if let errorMessage = errorMessage {
                sqlite3_bind_text(stmt, paramIndex, errorMessage, -1, SQLITE_TRANSIENT)
                paramIndex += 1
            }

            sqlite3_bind_int64(stmt, paramIndex, id)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Get a backup job by ID
    public func getBackupJob(id: Int64) -> BackupJob? {
        queue.sync {
            let sql = """
                SELECT id, destination_id, source_path, status, bytes_total, bytes_transferred,
                       files_total, files_transferred, transfer_speed, started_at, completed_at,
                       last_update, error_message, retry_count, priority
                FROM backup_jobs
                WHERE id = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, id)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return parseBackupJob(from: stmt)
            }

            return nil
        }
    }

    /// Get all backup jobs for a destination
    public func getBackupJobs(destinationId: Int64) -> [BackupJob] {
        queue.sync {
            var results: [BackupJob] = []

            let sql = """
                SELECT id, destination_id, source_path, status, bytes_total, bytes_transferred,
                       files_total, files_transferred, transfer_speed, started_at, completed_at,
                       last_update, error_message, retry_count, priority
                FROM backup_jobs
                WHERE destination_id = ?
                ORDER BY priority ASC, id ASC
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, destinationId)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let job = parseBackupJob(from: stmt) {
                    results.append(job)
                }
            }

            return results
        }
    }

    /// Get the active (running) backup job for a destination
    public func getActiveBackupJob(destinationId: Int64) -> BackupJob? {
        queue.sync {
            let sql = """
                SELECT id, destination_id, source_path, status, bytes_total, bytes_transferred,
                       files_total, files_transferred, transfer_speed, started_at, completed_at,
                       last_update, error_message, retry_count, priority
                FROM backup_jobs
                WHERE destination_id = ? AND status = 'RUNNING'
                LIMIT 1
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, destinationId)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return parseBackupJob(from: stmt)
            }

            return nil
        }
    }

    /// Get stale jobs (last_update exceeds threshold)
    public func getStaleJobs(thresholdSeconds: Int) -> [BackupJob] {
        queue.sync {
            var results: [BackupJob] = []

            let sql = """
                SELECT id, destination_id, source_path, status, bytes_total, bytes_transferred,
                       files_total, files_transferred, transfer_speed, started_at, completed_at,
                       last_update, error_message, retry_count, priority
                FROM backup_jobs
                WHERE status = 'RUNNING'
                  AND datetime(last_update, '+\(thresholdSeconds) seconds') < datetime('now')
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return results
            }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let job = parseBackupJob(from: stmt) {
                    results.append(job)
                }
            }

            return results
        }
    }

    /// Mark a job as interrupted
    public func markJobInterrupted(id: Int64) throws {
        try queue.sync {
            let sql = """
                UPDATE backup_jobs SET
                    status = 'INTERRUPTED',
                    last_update = datetime('now')
                WHERE id = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, id)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Mark a job as completed and update destination's last_backup_at
    public func markJobCompleted(id: Int64, bytesTransferred: Int64, filesTransferred: Int64) throws {
        try queue.sync {
            // Update the job
            let jobSql = """
                UPDATE backup_jobs SET
                    status = 'COMPLETED',
                    bytes_transferred = ?,
                    files_transferred = ?,
                    completed_at = datetime('now'),
                    last_update = datetime('now')
                WHERE id = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, jobSql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(stmt, 1, bytesTransferred)
            sqlite3_bind_int64(stmt, 2, filesTransferred)
            sqlite3_bind_int64(stmt, 3, id)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(stmt)

            // Update the destination's last_backup_at
            let destSql = """
                UPDATE backup_destinations SET
                    last_backup_at = datetime('now')
                WHERE id = (SELECT destination_id FROM backup_jobs WHERE id = ?)
            """

            guard sqlite3_prepare_v2(db, destSql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, id)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Increment the retry count for a backup job
    public func incrementJobRetryCount(id: Int64) throws {
        try queue.sync {
            let sql = """
                UPDATE backup_jobs SET
                    retry_count = retry_count + 1,
                    last_update = datetime('now')
                WHERE id = ?
            """
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, id)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Reset all backup jobs for a destination (delete them)
    public func resetBackupJobs(destinationId: Int64) throws {
        try queue.sync {
            let sql = "DELETE FROM backup_jobs WHERE destination_id = ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TrackerError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, destinationId)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw TrackerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Helper to parse a BackupJob from a prepared statement
    private func parseBackupJob(from stmt: OpaquePointer?) -> BackupJob? {
        guard let stmt = stmt else { return nil }

        let sqlFormatter = DateFormatter()
        sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlFormatter.timeZone = TimeZone(identifier: "UTC")

        let id = sqlite3_column_int64(stmt, 0)
        let destinationId = sqlite3_column_int64(stmt, 1)
        let sourcePath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let statusStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "PENDING"
        let status = BackupJobStatus(rawValue: statusStr) ?? .pending
        let bytesTotal = sqlite3_column_int64(stmt, 4)
        let bytesTransferred = sqlite3_column_int64(stmt, 5)
        let filesTotal = sqlite3_column_int64(stmt, 6)
        let filesTransferred = sqlite3_column_int64(stmt, 7)
        let transferSpeed = sqlite3_column_int64(stmt, 8)

        var startedAt: Date? = nil
        if sqlite3_column_type(stmt, 9) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 9) {
            startedAt = sqlFormatter.date(from: String(cString: cStr))
        }

        var completedAt: Date? = nil
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 10) {
            completedAt = sqlFormatter.date(from: String(cString: cStr))
        }

        var lastUpdate = Date()
        if let cStr = sqlite3_column_text(stmt, 11) {
            lastUpdate = sqlFormatter.date(from: String(cString: cStr)) ?? Date()
        }

        var errorMessage: String? = nil
        if sqlite3_column_type(stmt, 12) != SQLITE_NULL,
           let cStr = sqlite3_column_text(stmt, 12) {
            errorMessage = String(cString: cStr)
        }

        let retryCount = Int(sqlite3_column_int(stmt, 13))
        let priority = Int(sqlite3_column_int(stmt, 14))

        return BackupJob(
            id: id,
            destinationId: destinationId,
            sourcePath: sourcePath,
            status: status,
            bytesTotal: bytesTotal,
            bytesTransferred: bytesTransferred,
            filesTotal: filesTotal,
            filesTransferred: filesTransferred,
            transferSpeed: transferSpeed,
            startedAt: startedAt,
            completedAt: completedAt,
            lastUpdate: lastUpdate,
            errorMessage: errorMessage,
            retryCount: retryCount,
            priority: priority
        )
    }
}

public enum TrackerError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
}
