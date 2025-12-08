# Product Roadmap

## Completed Features

- [x] Apple Photos library enumeration and metadata extraction
- [x] Immich API integration for asset upload
- [x] SQLite tracker database with UUID-to-Immich mapping
- [x] Live Photo support with motion video linking
- [x] Cinematic video backup (depth track, AAE sidecars)
- [x] Special media type detection (Portrait, HDR, Panorama, Slo-mo, Timelapse, Spatial Video, ProRAW)
- [x] iCloud asset download for cloud-only media
- [x] Incremental sync (skip already-imported assets)
- [x] Problem asset tracking (failed/skipped with reasons)
- [x] Repair tools (reclassify, repair-paired-videos, repair-cinematic)
- [x] Review command for problem asset management
- [x] Cleanup command for deleted asset tracking removal
- [x] Encrypted cloud backup to Backblaze B2 with resumable job tracking

## Roadmap

1. [ ] Archive workflow - Track assets marked as archived (removed from iCloud but kept in Immich), add `archive` command to mark assets, update tracker schema with archive status `M`

2. [ ] Unarchive/restore workflow - Restore archived assets from Immich back to Apple Photos using PHAssetCreationRequest, handle Live Photos and metadata restoration `L`

3. [ ] Reverse sync (Immich -> Apple Photos) - Import assets from Immich that don't exist in Apple Photos, support importing media from other sources (cameras, Android, etc.) into both Immich and Apple Photos `L`

4. [ ] Modification detection - Detect when assets have been edited in either Apple Photos or Immich, track modification dates, flag for user review or re-sync `M`

5. [ ] Album sync - Sync Apple Photos albums to Immich albums, maintain album membership in tracker, support album changes `M`

6. [ ] Shared library support - Handle iCloud Shared Photo Library assets, track which library assets belong to, sync shared library to Immich `M`

7. [ ] Cold storage tiered archival - Extend backup command to support tiered storage (Immich for active, cold storage for archive), add AWS Glacier support, track cold storage status for individual assets `M`

8. [ ] Mac app with SwiftUI - Native Mac app wrapping CLI functionality, menu bar status indicator, background sync scheduling, visual progress and status dashboard `XL`

> Notes
> - Order items by technical dependencies and product architecture
> - Items 1-3 complete the core round-trip sync vision
> - Items 4-6 enhance sync reliability and feature parity
> - Items 7-8 are long-term enhancements
> - Each item should represent an end-to-end functional and testable feature
