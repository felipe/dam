# Raw Idea: Add backup command with encrypted cloud storage support

## Feature Description

Add a `photos-sync backup` command to backup Immich data to encrypted cloud storage (Backblaze B2, with architecture supporting future backends like Glacier/S3).

## Critical Requirements

- Local Immich has ~1TB of data that needs offsite backup
- Backups must be encrypted (client-side via rclone crypt + server-side)
- Large backups will be interrupted (network drops, sleep, restarts) and must resume gracefully

## Key Functionality

- Check prerequisites (rclone, 1Password CLI)
- Get credentials from 1Password
- Configure rclone crypt for encryption
- Execute backup via rclone subprocess
- Track job state in tracker.db for resumable backups
- Support multiple destinations (B2 primary, Glacier/S3 future)

## Date Initiated
2025-12-07
