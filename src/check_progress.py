#!/usr/bin/env python3
"""Check iCloud sync progress and optionally import ready files."""

import argparse
import sys
from pathlib import Path

try:
    import osxphotos
except ImportError:
    print("ERROR: osxphotos not installed")
    sys.exit(1)

from utils.config import config
from utils.tracker import ImportTracker


def main():
    parser = argparse.ArgumentParser(description="Check iCloud sync progress")
    parser.add_argument(
        "--photos-library",
        type=str,
        default="/Volumes/Ext 4T/Photos Library.photoslibrary",
        help="Path to Photos library",
    )
    args = parser.parse_args()

    # Load config and tracker
    cfg = config()
    tracker = ImportTracker(cfg.tracker_db_path)
    imported_uuids = tracker.get_imported_uuids()

    # Open Photos library
    print(f"Opening: {args.photos_library}")
    db = osxphotos.PhotosDB(args.photos_library)
    photos = db.photos()

    # Count stats
    total = len(photos)
    local = 0
    cloud = 0
    already_imported = 0
    ready_to_import = 0

    for p in photos:
        if p.uuid in imported_uuids:
            already_imported += 1
        elif p.path and Path(p.path).exists():
            local += 1
            ready_to_import += 1
        else:
            cloud += 1

    # Library size
    lib_path = Path(args.photos_library)
    lib_size = sum(f.stat().st_size for f in lib_path.rglob("*") if f.is_file())
    lib_size_gb = lib_size / (1024**3)

    print()
    print("=" * 50)
    print("SYNC PROGRESS")
    print("=" * 50)
    print(f"Library size:     {lib_size_gb:.2f} GB")
    print(f"Total photos:     {total:,}")
    print(f"  Downloaded:     {local:,}")
    print(f"  Still in cloud: {cloud:,}")
    print()
    print(f"Already in Immich: {already_imported:,}")
    print(f"Ready to import:   {ready_to_import:,}")
    print()
    
    if ready_to_import > 0:
        print("Run this to import ready files:")
        print(f'  python drain_icloud.py --local-only --photos-library "{args.photos_library}"')


if __name__ == "__main__":
    main()
