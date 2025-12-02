"""SQLite-based import tracking for DAM."""

import sqlite3
from pathlib import Path
from datetime import datetime
from typing import Optional
from dataclasses import dataclass


@dataclass
class ImportedAsset:
    """Represents an imported asset record."""

    icloud_uuid: str
    immich_id: Optional[str]
    filename: str
    file_size: int
    media_type: str  # 'photo' or 'video'
    imported_at: datetime


class ImportTracker:
    """Track which iCloud assets have been imported to Immich."""

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._conn: Optional[sqlite3.Connection] = None
        self._ensure_schema()

    def _get_conn(self) -> sqlite3.Connection:
        """Get or create database connection."""
        if self._conn is None:
            self._conn = sqlite3.connect(self.db_path)
            self._conn.row_factory = sqlite3.Row
        return self._conn

    def _ensure_schema(self) -> None:
        """Create database schema if it doesn't exist."""
        conn = self._get_conn()
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS imported_assets (
                icloud_uuid TEXT PRIMARY KEY,
                immich_id TEXT,
                filename TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                media_type TEXT NOT NULL,
                imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE INDEX IF NOT EXISTS idx_imported_at 
                ON imported_assets(imported_at);
            
            CREATE INDEX IF NOT EXISTS idx_media_type 
                ON imported_assets(media_type);
        """
        )
        conn.commit()

    def is_imported(self, icloud_uuid: str) -> bool:
        """Check if an asset has already been imported."""
        conn = self._get_conn()
        cursor = conn.execute(
            "SELECT 1 FROM imported_assets WHERE icloud_uuid = ?", (icloud_uuid,)
        )
        return cursor.fetchone() is not None

    def get_imported_uuids(self) -> set[str]:
        """Get all imported iCloud UUIDs as a set for fast lookup."""
        conn = self._get_conn()
        cursor = conn.execute("SELECT icloud_uuid FROM imported_assets")
        return {row["icloud_uuid"] for row in cursor.fetchall()}

    def mark_imported(
        self,
        icloud_uuid: str,
        immich_id: Optional[str],
        filename: str,
        file_size: int,
        media_type: str,
    ) -> None:
        """Mark an asset as imported."""
        conn = self._get_conn()
        conn.execute(
            """
            INSERT OR REPLACE INTO imported_assets 
                (icloud_uuid, immich_id, filename, file_size, media_type, imported_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """,
            (icloud_uuid, immich_id, filename, file_size, media_type, datetime.now()),
        )
        conn.commit()

    def get_stats(self) -> dict:
        """Get import statistics."""
        conn = self._get_conn()

        # Total count
        total = conn.execute("SELECT COUNT(*) FROM imported_assets").fetchone()[0]

        # By media type
        photos = conn.execute(
            "SELECT COUNT(*) FROM imported_assets WHERE media_type = 'photo'"
        ).fetchone()[0]
        videos = conn.execute(
            "SELECT COUNT(*) FROM imported_assets WHERE media_type = 'video'"
        ).fetchone()[0]

        # Total size
        total_size = (
            conn.execute("SELECT SUM(file_size) FROM imported_assets").fetchone()[0]
            or 0
        )

        # Last import
        last_import = conn.execute(
            "SELECT MAX(imported_at) FROM imported_assets"
        ).fetchone()[0]

        return {
            "total": total,
            "photos": photos,
            "videos": videos,
            "total_size_bytes": total_size,
            "total_size_gb": round(total_size / (1024**3), 2),
            "last_import": last_import,
        }

    def get_recent(self, limit: int = 10) -> list[ImportedAsset]:
        """Get recently imported assets."""
        conn = self._get_conn()
        cursor = conn.execute(
            """
            SELECT * FROM imported_assets 
            ORDER BY imported_at DESC 
            LIMIT ?
        """,
            (limit,),
        )
        return [
            ImportedAsset(
                icloud_uuid=row["icloud_uuid"],
                immich_id=row["immich_id"],
                filename=row["filename"],
                file_size=row["file_size"],
                media_type=row["media_type"],
                imported_at=datetime.fromisoformat(row["imported_at"]),
            )
            for row in cursor.fetchall()
        ]

    def close(self) -> None:
        """Close database connection."""
        if self._conn:
            self._conn.close()
            self._conn = None

    def __enter__(self) -> "ImportTracker":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()
