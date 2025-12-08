# DAM - Digital Asset Migration

A tool for migrating photos and videos from Apple Photos/iCloud to [Immich](https://immich.app/), with encrypted cloud backup capabilities.

## Features

- **Photo & Video Import**: Export assets from Apple Photos library to Immich
- **Live Photo Support**: Preserves motion videos alongside still images with proper linking
- **Cinematic Video Support**: Backs up all components including depth track and AAE sidecars
- **Special Media Tracking**: Detects and tracks Portrait, HDR, Panorama, Slo-mo, Timelapse, Spatial Video, ProRAW
- **Incremental Sync**: Tracks imported assets to avoid duplicates
- **iCloud Support**: Can attempt to download assets stored in iCloud when requested
- **Repair Tools**: Verify and fix assets that may not have synced correctly
- **Encrypted Cloud Backup**: Backup Immich data to Backblaze B2 with client-side encryption

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

3. Grant Photos access when prompted (System Settings -> Privacy -> Photos)

## Recommended Immich Settings

### Storage Template

In Immich, go to **Administration -> Settings -> Storage Template** and set:

```
{{y}}/{{MM}}/{{dd}}_{{HH}}{{mm}}{{ss}}-{{filetype}}-{{assetIdShort}}
```

This template is recommended because:
- **Human readable**: Files are organized by year/month with clear date-based names
- **Source agnostic**: Works well when importing from multiple sources (Photos.app, camera imports, etc.)
- **Sortable**: Files sort chronologically by filename
- **Unique**: Short asset ID prevents collisions for photos taken at the same second

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

### `photos-sync backup`

Backup Immich data to encrypted cloud storage (Backblaze B2).

```bash
# Check prerequisites
photos-sync backup --check

# Run setup wizard
photos-sync backup --setup

# Run backup
photos-sync backup

# Backup to a specific destination
photos-sync backup --to b2

# Show backup status
photos-sync backup --status

# Preview what would be synced (dry run)
photos-sync backup --dry-run

# Force backup ignoring stale jobs
photos-sync backup --force

# Reset all job state for fresh start
photos-sync backup --reset
```

**Flags:**
- `--check` - Validate prerequisites (rclone, 1Password CLI)
- `--setup` - Run interactive setup wizard
- `--to <name>` - Backup to specific destination (default: b2)
- `--status` - Show backup status from database
- `--force` - Ignore stale job detection and proceed
- `--dry-run` - Preview what would be synced without transferring
- `--reset` - Clear all job state for destination

## Backup Feature

The backup command enables encrypted offsite backup of your Immich data to Backblaze B2 cloud storage.

### Prerequisites

Before using backup, install these tools:

```bash
# Install rclone (handles file sync)
brew install rclone

# Install 1Password CLI (manages credentials securely)
brew install 1password-cli

# Sign in to 1Password CLI
op signin
```

### Configuration

Add these variables to your `.env` file:

```bash
# Path to Immich data directory (required)
BACKUP_IMMICH_PATH=/path/to/immich/data

# Stats interval in seconds (default: 60)
# Used for stale job detection
BACKUP_STATS_INTERVAL=60

# Maximum retry attempts for failed jobs (default: 3)
BACKUP_MAX_RETRIES=3
```

### Setup Process

1. **Check prerequisites**:
   ```bash
   photos-sync backup --check
   ```
   This verifies rclone and 1Password CLI are installed and signed in.

2. **Run the setup wizard**:
   ```bash
   photos-sync backup --setup
   ```
   The wizard will:
   - Check prerequisites
   - Create or locate a 1Password item for credentials
   - Guide you to add your B2 application key
   - Configure rclone remotes (B2 + encryption)
   - Test encryption with a test write
   - Save the destination configuration

3. **Add your B2 credentials**:
   - Go to Backblaze B2 and create an Application Key
   - Open 1Password and find "Immich Backup B2"
   - Fill in: `application_key_id`, `application_key`, `bucket_name`
   - The `encryption_password` is auto-generated

### Running Backups

```bash
# Run a backup
photos-sync backup

# Preview without transferring files
photos-sync backup --dry-run

# Check status
photos-sync backup --status
```

### Backup Status

The `--status` flag shows detailed backup information:
- Last backup time per destination
- Job counts (completed, running, pending, failed)
- Total bytes and files transferred
- Current progress if a backup is running
- Warnings about stale or failed jobs

### Architecture

#### Client-Side Encryption
All data is encrypted **before** leaving your computer using rclone's crypt backend:
- Files are encrypted with your unique encryption password
- Filenames are also encrypted
- Even Backblaze cannot read your data
- Encryption password is stored securely in 1Password

#### Job Tracking and Resumability
Backups can span multiple terabytes and may be interrupted:
- Each source directory is a separate job with priority
- Progress is tracked in the database (bytes, files, speed)
- Interrupted backups resume where they left off
- Stale detection prevents orphaned running jobs

#### 1Password Credential Storage
Credentials never touch disk or config files:
- B2 keys stored in 1Password vault
- Encryption password generated and stored in 1Password
- Retrieved at runtime via `op` CLI
- No secrets in `.env` or rclone.conf

#### Directories Backed Up
The following Immich directories are backed up (in priority order):
1. `library/` - Main photo/video library (priority 1)
2. `upload/` - Uploaded files pending processing (priority 2)
3. `profile/` - User profile images (priority 3)
4. `backups/` - Immich database backups (priority 4)
5. `dam/data/` - Local DAM tracking database (priority 5)

Directories like `thumbs/` and `encoded-video/` are skipped as they can be regenerated.

### Troubleshooting

#### Stale Job Recovery

If a backup was interrupted (network drop, sleep, etc.), you may see stale job warnings:

```
WARNING: Found 1 stale job(s):
  - library: Last update 2 hours ago
```

Options:
- `--force` - Mark stale jobs as interrupted and resume
- `--reset` - Clear all job state and start fresh

```bash
# Resume interrupted backup
photos-sync backup --force

# Start completely fresh
photos-sync backup --reset
```

#### 1Password Sign-in Issues

If you see "1Password CLI is not signed in":

```bash
# Sign in to 1Password
op signin

# Verify sign-in worked
op account get
```

Make sure:
- You have 1Password desktop app installed
- The CLI is linked to your account
- Touch ID or password authentication is available

#### rclone Configuration Debugging

If rclone isn't working properly:

```bash
# List configured remotes
rclone listremotes

# Test B2 connection
rclone lsd b2-b2:

# Test crypt remote
rclone lsd b2-crypt:

# Check rclone config
rclone config show
```

Common issues:
- Expired B2 application key - create a new one in B2 dashboard
- Wrong bucket name - verify in 1Password item
- Missing encryption password - check 1Password item has all 4 fields

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
│   ├── backup.log          # Latest backup execution log
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

The `backup_destinations` table tracks:
- `id` - Unique destination ID
- `name` - Destination name (e.g., "b2")
- `type` - Destination type (e.g., "b2")
- `bucket_name` - Cloud bucket name
- `remote_path` - Path within the bucket
- `created_at` - When configured
- `last_backup_at` - Last successful backup timestamp

The `backup_jobs` table tracks:
- `id` - Unique job ID
- `destination_id` - Foreign key to destination
- `source_path` - Local directory being backed up
- `status` - PENDING, RUNNING, COMPLETED, INTERRUPTED, FAILED
- `bytes_total`, `bytes_transferred` - Transfer progress
- `files_total`, `files_transferred` - File counts
- `transfer_speed` - Current speed in bytes/sec
- `started_at`, `completed_at`, `last_update` - Timestamps
- `error_message` - Error details for failed jobs
- `retry_count` - Number of retry attempts
- `priority` - Execution order

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
