#!/usr/bin/env python3
"""
Drain iCloud Photos to Immich.

Exports photos/videos from iCloud (via Photos.app) and uploads them to Immich.
Handles limited disk space by processing in batches with --download-missing.
"""

import argparse
import sys
import shutil
from pathlib import Path
from datetime import datetime

try:
    import osxphotos
except ImportError:
    print("ERROR: osxphotos not installed. Run: pip install osxphotos")
    sys.exit(1)

from utils.config import config
from utils.tracker import ImportTracker
from utils.immich_client import ImmichClient, UploadResult
from utils.exif_utils import get_media_type, should_skip_file


def log(msg: str, level: str = "INFO") -> None:
    """Print a log message with timestamp."""
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {level}: {msg}")


def format_size(size_bytes: float) -> str:
    """Format bytes as human-readable size."""
    for unit in ["B", "KB", "MB", "GB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def get_photos_to_import(
    photosdb: osxphotos.PhotosDB, imported_uuids: set[str], local_only: bool = False
) -> list:
    """
    Get list of photos not yet imported.

    Args:
        photosdb: osxphotos PhotosDB instance
        imported_uuids: Set of already-imported iCloud UUIDs
        local_only: If True, only return photos available locally

    Returns:
        List of PhotoInfo objects to import (local files first, then cloud)
    """
    all_photos = photosdb.photos()
    local_photos = []
    cloud_photos = []

    for photo in all_photos:
        # Skip if already imported
        if photo.uuid in imported_uuids:
            continue

        # Skip junk files
        if photo.original_filename and should_skip_file(photo.original_filename):
            continue

        # Categorize by availability
        if photo.path and Path(photo.path).exists():
            local_photos.append(photo)
        elif not local_only:
            cloud_photos.append(photo)

    # Return local first, then cloud (prioritize fast exports)
    return local_photos + cloud_photos


def build_batch(photos: list, max_bytes: int, max_items: int = 0) -> list:
    """
    Build a batch of photos that fit within size and item limits.

    Args:
        photos: List of PhotoInfo objects
        max_bytes: Maximum batch size in bytes
        max_items: Maximum number of items (0 = no limit)

    Returns:
        List of PhotoInfo objects for this batch
    """
    batch = []
    batch_size = 0

    for photo in photos:
        # Check item limit
        if max_items and len(batch) >= max_items:
            break
            
        # Get file size (original_filesize or estimate)
        file_size = photo.original_filesize or 0

        # If we can't determine size, estimate based on type
        if file_size == 0:
            if photo.isphoto:
                file_size = 5 * 1024 * 1024  # 5MB estimate for photos
            else:
                file_size = 100 * 1024 * 1024  # 100MB estimate for videos

        # Check if adding this would exceed size limit
        if batch_size + file_size > max_bytes and batch:
            break

        batch.append(photo)
        batch_size += file_size

    return batch


def export_photo(photo, staging_dir: Path) -> Path | None:
    """
    Export a photo to staging directory.

    Strategy:
    1. If photo has local path, copy directly (fast)
    2. Otherwise use osxphotos CLI with --download-missing (handles timeouts better)

    Args:
        photo: osxphotos PhotoInfo object
        staging_dir: Directory to export to

    Returns:
        Path to exported file, or None if export failed
    """
    import subprocess
    
    try:
        # Check if file is available locally
        if photo.path and Path(photo.path).exists():
            # Direct copy - much faster
            exported_files = photo.export(
                str(staging_dir),
                use_photos_export=False,
                overwrite=True,
            )
            if exported_files:
                return Path(exported_files[0])
        else:
            # Use CLI for iCloud downloads - better timeout handling
            log(f"  Downloading from iCloud...")
            result = subprocess.run(
                [
                    "osxphotos", "export", str(staging_dir),
                    "--uuid", photo.uuid,
                    "--download-missing",
                    "--overwrite",
                    "--skip-edited",
                    "--skip-live",
                    "--no-progress",
                ],
                capture_output=True,
                text=True,
                timeout=300,  # 5 minute timeout per file
            )
            
            if result.returncode == 0:
                # Find the exported file
                for f in staging_dir.iterdir():
                    if f.is_file():
                        return f
            else:
                log(f"CLI export failed: {result.stderr}", "ERROR")
                return None

        log(f"No file exported for {photo.original_filename}", "WARN")
        return None

    except subprocess.TimeoutExpired:
        log(f"Export timed out for {photo.original_filename}", "ERROR")
        return None
    except Exception as e:
        log(f"Export exception for {photo.original_filename}: {e}", "ERROR")
        return None


def process_batch(
    batch: list,
    staging_dir: Path,
    immich: ImmichClient,
    tracker: ImportTracker,
    dry_run: bool = False,
) -> dict:
    """
    Process a batch of photos: export, upload, track.

    Args:
        batch: List of PhotoInfo objects
        staging_dir: Staging directory for exports
        immich: Immich client
        tracker: Import tracker
        dry_run: If True, don't actually upload

    Returns:
        Dict with success/failure counts
    """
    stats = {"exported": 0, "uploaded": 0, "duplicates": 0, "failed": 0, "skipped": 0}

    import time
    
    for i, photo in enumerate(batch, 1):
        filename = photo.original_filename or f"unknown_{photo.uuid}"
        media_type = get_media_type(filename) or ("photo" if photo.isphoto else "video")
        is_cloud = not (photo.path and Path(photo.path).exists())

        log(f"[{i}/{len(batch)}] Processing: {filename}")

        if dry_run:
            log(f"  DRY RUN: Would export and upload {filename}")
            stats["skipped"] += 1
            continue

        # Export to staging
        exported_path = export_photo(photo, staging_dir)
        
        # Be gentle with iCloud - pause between downloads
        if is_cloud and exported_path and i < len(batch):
            log(f"  Pausing 30s before next iCloud download...")
            time.sleep(30)
        if not exported_path:
            stats["failed"] += 1
            continue

        stats["exported"] += 1
        file_size = exported_path.stat().st_size
        log(f"  Exported: {format_size(file_size)}")

        # Get timestamps - Immich wants ISO 8601 with timezone
        # Use file creation time from the exported file as fallback
        file_stat = exported_path.stat()
        
        def format_date(dt) -> str | None:
            """Format datetime for Immich API."""
            if dt is None:
                return None
            # Ensure we have timezone info (assume UTC if naive)
            if dt.tzinfo is None:
                from datetime import timezone
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        
        created_at = format_date(photo.date)
        modified_at = format_date(photo.date_modified)
        
        # Use file timestamps as fallback
        if not created_at:
            created_at = datetime.fromtimestamp(file_stat.st_birthtime).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        if not modified_at:
            modified_at = datetime.fromtimestamp(file_stat.st_mtime).strftime("%Y-%m-%dT%H:%M:%S.000Z")

        # Upload to Immich
        result: UploadResult = immich.upload_asset(
            file_path=exported_path,
            device_asset_id=photo.uuid,
            device_id="dam-icloud-drain",
            file_created_at=created_at,
            file_modified_at=modified_at,
        )

        if result.success:
            if result.duplicate:
                log(f"  Duplicate detected in Immich")
                stats["duplicates"] += 1
            else:
                log(f"  Uploaded: {result.asset_id}")
                stats["uploaded"] += 1

            # Track as imported
            tracker.mark_imported(
                icloud_uuid=photo.uuid,
                immich_id=result.asset_id,
                filename=filename,
                file_size=file_size,
                media_type=media_type,
            )
        else:
            log(f"  Upload failed: {result.error}", "ERROR")
            stats["failed"] += 1

        # Clean up staging file
        try:
            exported_path.unlink()
        except Exception as e:
            log(f"  Failed to delete staging file: {e}", "WARN")

    return stats


def main():
    parser = argparse.ArgumentParser(
        description="Drain iCloud Photos to Immich",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python drain_icloud.py --dry-run          # Preview what would be imported
  python drain_icloud.py --local-only       # Only import locally-cached photos
  python drain_icloud.py --batch-size 5     # Import with 5GB batches
  python drain_icloud.py --max-items 50     # Limit to 50 items per batch (good for iCloud)
  python drain_icloud.py --stats            # Show import statistics
        """,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview imports without uploading",
    )
    parser.add_argument(
        "--batch-size",
        type=float,
        help="Batch size in GB (default: from config)",
    )
    parser.add_argument(
        "--max-batches",
        type=int,
        default=0,
        help="Maximum number of batches to process (0 = unlimited)",
    )
    parser.add_argument(
        "--stats",
        action="store_true",
        help="Show import statistics and exit",
    )
    parser.add_argument(
        "--photos-library",
        type=str,
        help="Path to Photos library (default: system default)",
    )
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Only import photos that are already downloaded locally (skip iCloud)",
    )
    parser.add_argument(
        "--max-items",
        type=int,
        default=0,
        help="Maximum items per batch (useful for iCloud downloads, 0 = no limit)",
    )

    args = parser.parse_args()

    # Load configuration
    try:
        cfg = config()
    except ValueError as e:
        print(f"Configuration error: {e}")
        print("Make sure .env file exists with IMMICH_URL and IMMICH_API_KEY")
        sys.exit(1)

    # Override config with CLI args
    dry_run = args.dry_run or cfg.dry_run
    batch_size_bytes = (
        int(args.batch_size * 1024**3) if args.batch_size else cfg.batch_size_bytes
    )

    # Ensure directories exist
    cfg.ensure_dirs()

    # Initialize tracker
    tracker = ImportTracker(cfg.tracker_db_path)

    # Stats only mode
    if args.stats:
        stats = tracker.get_stats()
        print("\n=== Import Statistics ===")
        print(f"Total imported:  {stats['total']:,}")
        print(f"  Photos:        {stats['photos']:,}")
        print(f"  Videos:        {stats['videos']:,}")
        print(f"Total size:      {stats['total_size_gb']:.2f} GB")
        print(f"Last import:     {stats['last_import'] or 'Never'}")
        return

    # Initialize Immich client
    immich = ImmichClient(cfg.immich_url, cfg.immich_api_key)

    # Test Immich connection
    log("Connecting to Immich...")
    if not immich.ping():
        log("Failed to connect to Immich. Check URL and API key.", "ERROR")
        sys.exit(1)
    log(f"Connected to Immich at {cfg.immich_url}")

    # Open Photos library
    log("Opening Photos library...")
    try:
        if args.photos_library:
            photosdb = osxphotos.PhotosDB(args.photos_library)
        else:
            photosdb = osxphotos.PhotosDB()
    except Exception as e:
        log(f"Failed to open Photos library: {e}", "ERROR")
        sys.exit(1)

    log(f"Photos library: {photosdb.library_path}")
    log(f"Total photos in library: {len(photosdb.photos()):,}")

    # Get already imported UUIDs
    imported_uuids = tracker.get_imported_uuids()
    log(f"Already imported: {len(imported_uuids):,}")

    # Get photos to import
    log("Scanning for new photos...")
    to_import = get_photos_to_import(photosdb, imported_uuids, local_only=args.local_only)
    
    if args.local_only:
        log(f"Local-only mode: {len(to_import):,} photos available locally")
    else:
        # Count local vs cloud
        local_count = sum(1 for p in to_import if p.path and Path(p.path).exists())
        cloud_count = len(to_import) - local_count
        log(f"New photos to import: {len(to_import):,} ({local_count:,} local, {cloud_count:,} need download)")

    if not to_import:
        log("Nothing to import. All photos are already in Immich.")
        return

    # Process in batches
    batch_num = 0
    total_stats = {"exported": 0, "uploaded": 0, "duplicates": 0, "failed": 0, "skipped": 0}

    while to_import:
        batch_num += 1

        # Check batch limit
        if args.max_batches and batch_num > args.max_batches:
            log(f"Reached max batches ({args.max_batches}). Stopping.")
            break

        # Build batch
        batch = build_batch(to_import, batch_size_bytes, args.max_items)
        if not batch:
            break

        # Remove batch items from to_import
        batch_uuids = {p.uuid for p in batch}
        to_import = [p for p in to_import if p.uuid not in batch_uuids]

        log(f"\n=== Batch {batch_num} ({len(batch)} items) ===")

        if dry_run:
            log("DRY RUN MODE - No actual uploads")

        # Process batch
        batch_stats = process_batch(
            batch=batch,
            staging_dir=cfg.staging_dir,
            immich=immich,
            tracker=tracker,
            dry_run=dry_run,
        )

        # Aggregate stats
        for key in total_stats:
            total_stats[key] += batch_stats[key]

        log(f"Batch {batch_num} complete: {batch_stats}")

        # Clean staging directory
        if not dry_run:
            for f in cfg.staging_dir.iterdir():
                try:
                    f.unlink()
                except Exception:
                    pass

    # Final summary
    print("\n" + "=" * 50)
    print("IMPORT COMPLETE")
    print("=" * 50)
    print(f"Exported:   {total_stats['exported']:,}")
    print(f"Uploaded:   {total_stats['uploaded']:,}")
    print(f"Duplicates: {total_stats['duplicates']:,}")
    print(f"Failed:     {total_stats['failed']:,}")
    if dry_run:
        print(f"Skipped (dry run): {total_stats['skipped']:,}")

    # Show tracker stats
    stats = tracker.get_stats()
    print(f"\nTotal in Immich: {stats['total']:,} ({stats['total_size_gb']:.2f} GB)")


if __name__ == "__main__":
    main()
