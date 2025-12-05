# DAM - Digital Asset Migration

A tool for migrating photos and videos from Apple Photos/iCloud to [Immich](https://immich.app/).

## Features

- **Photo & Video Import**: Export assets from Apple Photos library to Immich
- **Live Photo Support**: Preserves motion videos alongside still images
- **Cinematic Video Support**: Backs up all components of Apple Cinematic videos
- **Incremental Sync**: Tracks imported assets to avoid duplicates
- **iCloud Integration**: Can download assets stored in iCloud

## Components

- `swift/` - Native macOS app using PhotoKit for Photos library access
- `src/` - Python utilities for Immich API interaction

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

3. Run commands:
   ```bash
   photos-sync status    # Show sync status
   photos-sync import    # Import local assets
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
