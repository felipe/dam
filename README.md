# DAM - Digital Asset Migration

A tool for migrating photos and videos from Apple Photos/iCloud to [Immich](https://immich.app/).

## Features

- **Photo & Video Import**: Export assets from Apple Photos library to Immich
- **Live Photo Support**: Preserves motion videos alongside still images with proper linking
- **Cinematic Video Support**: Backs up all components including depth track and AAE sidecars
- **Special Media Tracking**: Detects and tracks Portrait, HDR, Panorama, Slo-mo, Timelapse, Spatial Video, ProRAW
- **Incremental Sync**: Tracks imported assets to avoid duplicates
- **iCloud Support**: Can attempt to download assets stored in iCloud when requested
- **Repair Tools**: Verify and fix assets that may not have synced correctly

## Setup

1. Copy `.env.example` to `.env` and configure:
   ```
   IMMICH_URL=http://your-immich-server:2283
   IMMICH_API_KEY=your-api-key
   ```

2. Build the Swift tool:
   ```bash
   cd swift
   swift build -c release
   ```

3. Grant Photos access when prompted (System Settings → Privacy → Photos)

## Recommended Immich Settings

### Storage Template

In Immich, go to **Administration → Settings → Storage Template** and set:

```
{{y}}/{{MM}}/{{dd}}_{{HH}}{{mm}}{{ss}}-{{filetype}}-{{assetIdShort}}
```

This organizes files by year/month with a filename that includes:
- Date and time (`2025/12/05_143022`)
- File type (`-photo-` or `-video-`)
- Short unique ID (`-abc123`)

Example: `2025/12/05_143022-photo-a1b2c3.heic`

## Commands

### `photos-sync status`

Show sync status and statistics.

```bash
photos-sync status
```

### `photos-sync import`

Import photos from Photos.app to Immich.

```bash
# Import locally available assets
photos-sync import

# Include iCloud assets (downloads them first)
photos-sync import --include-cloud

# Limit number of imports
photos-sync import --limit 100

# Preview without making changes
photos-sync import --dry-run

# Concurrent imports (be gentle with iCloud)
photos-sync import --concurrency 3 --delay 2.0
```

**Flags:**
- `--dry-run` - Preview what would be imported
- `--include-cloud` - Download and import iCloud assets
- `--skip-local-check` - Skip slow local availability check, fail fast on cloud assets
- `--limit N` - Maximum number of assets to process (0 = unlimited)
- `--concurrency N` - Number of concurrent imports (default: 1)
- `--delay N` - Seconds between imports (default: 5.0)

**Repair Flags:**
- `--repair-paired-videos` - Re-upload Live Photos/paired assets with their motion video
- `--repair-cinematic` - Export sidecars for previously imported Cinematic videos

### `photos-sync reclassify`

Scan Photos library and update tracker database with current subtype information.

```bash
# Scan and update subtypes in tracker
photos-sync reclassify

# Also repair assets with paired video missing their motion backup
photos-sync reclassify --repair --include-cloud

# Limit repairs
photos-sync reclassify --repair --repair-limit 50
```

**Flags:**
- `--dry-run` - Preview without making changes
- `--repair` - Also repair paired video assets
- `--repair-limit N` - Maximum repairs to process
- `--include-cloud` - Download from iCloud for repairs

### `photos-sync cleanup`

Remove tracking for assets deleted from Photos library.

```bash
photos-sync cleanup
photos-sync cleanup --dry-run
```

### `photos-sync sync`

Full sync: import new assets and cleanup deleted ones.

```bash
photos-sync sync
```

### `photos-sync review`

Review and manage problem assets (failed/skipped imports).

```bash
# Show problem assets grouped by reason
photos-sync review

# Export to JSON for analysis
photos-sync review --export problems.json

# Retry failed imports
photos-sync review --retry --include-cloud

# Delete orphaned/corrupted assets from Photos
photos-sync review --delete

# Preview deletions
photos-sync review --delete --dry-run

# Filter to specific status
photos-sync review --failed-only
photos-sync review --skipped-only
```

**Flags:**
- `--failed-only` - Show only failed assets
- `--skipped-only` - Show only skipped assets
- `--export FILE` - Export problem list to JSON
- `--retry` - Retry importing failed assets
- `--delete` - Delete problem assets from Photos (moves to Recently Deleted)
- `--dry-run` - Preview without making changes
- `--include-cloud` - Allow iCloud downloads during retry
- `--limit N` - Maximum assets to process

## Asset Subtypes Tracked

The tracker database stores subtype flags for each imported asset:

| Subtype | Detection | Notes |
|---------|-----------|-------|
| Live Photo | `.photoLive` subtype | Has paired video component |
| Portrait | `.photoDepthEffect` subtype | |
| HDR | `.photoHDR` subtype | |
| Panorama | `.photoPanorama` subtype | |
| Screenshot | `.photoScreenshot` subtype | |
| Cinematic | `.videoCinematic` subtype | Has depth track + AAE sidecar |
| Slo-mo | `.videoHighFrameRate` subtype | |
| Timelapse | `.videoTimelapse` subtype | |
| Spatial Video | Raw subtype flag `0x400000` | Apple Vision Pro content |
| ProRAW | UTI `com.adobe.raw-image` | DNG format |
| Has Paired Video | `.pairedVideo` resource check | Actual resource, not subtype flag |

## Data Storage

```
dam/
├── data/
│   ├── tracker.db          # SQLite database tracking all imports
│   └── sidecars/           # Cinematic video sidecars
│       └── {asset_id}/     # Per-asset sidecar directory
│           ├── VIDEO.AAE   # Adjustment data
│           ├── VIDEO_base.MOV      # Pre-edit video (if edited)
│           └── VIDEO_rendered.MOV  # Rendered video (if edited)
└── .env                    # Configuration
```

### Tracker Database Schema

The `imported_assets` table tracks:
- `icloud_uuid` - Photos library local identifier (primary key)
- `immich_id` - Corresponding Immich asset ID
- `filename`, `file_size`, `media_type`
- `imported_at` - Timestamp
- `archived` - Whether deleted from Photos but kept in Immich
- `is_live_photo`, `is_portrait`, `is_hdr`, etc. - Subtype flags
- `has_paired_video` - Resource-based paired video detection
- `motion_video_immich_id` - Linked motion video in Immich
- `cinematic_sidecars` - JSON array of sidecar filenames
- `status` - Import status: `imported`, `failed`, or `skipped`
- `error_reason` - Reason for failure/skip
- `asset_created_at` - Original asset creation date (helps locate in Photos)

## Problem Asset Tracking

Failed and skipped imports are tracked in the database with reasons. Use `photos-sync review` to inspect and manage them.

Common issues:
- **"No resource found"** - Orphaned metadata with no actual photo data (often `.dat` files from old iCloud sync issues). Safe to delete.
- **"PHPhotosErrorDomain error 3169"** - iCloud download failed temporarily. Retry later with `--retry --include-cloud`.
- **"Download failed"** - Network or Photos access issue. Retry later.

```bash
# Check for problems
photos-sync status

# Review and manage
photos-sync review

# Retry transient failures
photos-sync review --retry --include-cloud

# Delete unrecoverable orphans
photos-sync review --delete
```

## Repair Tools

If you believe something didn't sync correctly, these tools can help verify and fix issues.

### Verify Live Photo Sync

```bash
# Check status of paired video assets
photos-sync reclassify

# Re-sync Live Photos with their motion video
photos-sync import --repair-paired-videos --include-cloud
```

### Verify Cinematic Video Sync

```bash
# Export sidecars for Cinematic videos
photos-sync import --repair-cinematic --include-cloud
```

## Known Limitations

### Cinematic Video Round-Trip Restoration

**Status**: Tracking in [Issue #9](../../issues/9) - kept open for potential future Apple API changes.

Apple Cinematic videos are fully backed up with all their components:
- Main video with embedded depth track
- AAE adjustment data (edit history)
- Base video (pre-edit state, if edited)
- Rendered video (baked effects, if edited)

**However**, there is an architectural limitation with restoring Cinematic videos back to Apple Photos with full editing capability:

When re-importing a Cinematic video to Photos.app via `PHAssetCreationRequest`, the video imports as a regular video - you cannot resume focus point editing. This is because:

1. **Focus keyframes are in MOV metadata**, not the AAE file. While this data is preserved, Photos.app doesn't recognize re-imported files as Cinematic.

2. **Apple's ecosystem lock**: The Cinematic designation appears to require original capture metadata or private APIs that aren't exposed to third-party apps.

3. **Neural Engine processing**: The depth/focus system relies on on-device ML models during capture that can't be replicated post-hoc.

**Workarounds**:
- Keep originals in iCloud Photos as the authoritative source for focus editing
- Use Final Cut Pro which can import and edit Cinematic video focus points from MOV files
- The backed-up files preserve all data for potential future restoration if Apple provides APIs

**What IS preserved**:
- Full visual quality of the video
- Embedded depth track data
- All adjustment/edit history
- Complete data for archival purposes

While Cinematic videos are fully backed up, restoring the interactive focus-editing experience requires the original in Apple Photos or using Final Cut Pro.
