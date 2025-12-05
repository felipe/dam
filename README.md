# DAM - Digital Asset Migration

A tool for migrating photos and videos from Apple Photos/iCloud to [Immich](https://immich.app/).

## Features

- **Photo & Video Import**: Export assets from Apple Photos library to Immich
- **Live Photo Support**: Preserves motion videos alongside still images with proper linking
- **Cinematic Video Support**: Backs up all components including depth track and AAE sidecars
- **Special Media Tracking**: Detects and tracks Portrait, HDR, Panorama, Slo-mo, Timelapse, Spatial Video, ProRAW
- **Incremental Sync**: Tracks imported assets to avoid duplicates
- **iCloud Integration**: Can download assets stored in iCloud
- **Repair Tools**: Fix previously imported assets that are missing components

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

Scan Photos library and update tracker database with current subtype information. Useful after the subtype tracking feature was added to fix historical imports.

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

## Asset Subtypes Tracked

The tracker database stores subtype flags for each imported asset:

| Subtype | Detection | Notes |
|---------|-----------|-------|
| Live Photo | `.photoLive` subtype | Has paired video component |
| Portrait | `.photoDepthEffect` subtype | Depth data stored differently, no paired video |
| HDR | `.photoHDR` subtype | Exposure data embedded, no paired video |
| Panorama | `.photoPanorama` subtype | |
| Screenshot | `.photoScreenshot` subtype | |
| Cinematic | `.videoCinematic` subtype | Has depth track + AAE sidecar |
| Slo-mo | `.videoHighFrameRate` subtype | |
| Timelapse | `.videoTimelapse` subtype | |
| Spatial Video | Raw subtype flag `0x400000` | Apple Vision Pro content |
| ProRAW | UTI `com.adobe.raw-image` | DNG format |
| Has Paired Video | `.pairedVideo` resource check | Actual resource, not subtype flag |

**Key Discovery:** Portrait and HDR photos do NOT have paired video resources. Their depth/exposure data is stored differently (embedded in the file). Only Live Photos (and corrupted Live Photos that lost their subtype flag) have `.pairedVideo` resources.

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

## Repair Workflows

### Live Photos Missing Motion Video

If Live Photos were imported before motion video support was added:

```bash
# Check how many need repair
photos-sync reclassify

# Repair them (re-uploads with proper video linking)
photos-sync import --repair-paired-videos --include-cloud
```

### Cinematic Videos Missing Sidecars

If Cinematic videos were imported before sidecar support:

```bash
# Export sidecars for existing Cinematic imports
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

1. **Focus keyframes are in MOV metadata**, not the AAE file. While we preserve this data, Photos.app doesn't recognize re-imported files as Cinematic.

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

This limitation is documented here so users understand that while Cinematic videos are fully backed up, restoring the interactive focus-editing experience requires the original in Apple Photos or using Final Cut Pro.

## Components

- `swift/` - Native macOS app using PhotoKit for Photos library access
- `src/` - Python utilities for Immich API interaction (legacy)
