# Specification: Backup Command

## Goal
Add a `photos-sync backup` command to backup Immich data to encrypted cloud storage (Backblaze B2 primary, with architecture supporting future backends like Glacier/S3), with resumable job tracking for large multi-terabyte backups that may be interrupted.

## User Stories
- As a user, I want to backup my Immich library to encrypted cloud storage so that I have offsite protection for my photos and videos
- As a user, I want backup jobs to resume gracefully after interruptions (network drops, sleep, restarts) so that I don't restart 1TB+ uploads from scratch

## Specific Requirements

**Command Interface**
- `photos-sync backup --check` validates prerequisites (rclone, 1Password CLI installed and accessible)
- `photos-sync backup --setup b2` runs interactive wizard to configure a destination
- `photos-sync backup` runs backup using default destination
- `photos-sync backup --to b2` runs backup to a specific named destination
- `photos-sync backup --status` shows database state and progress (not live logs)
- `photos-sync backup --to b2 --force` runs backup ignoring stale job detection
- `photos-sync backup --to b2 --dry-run` shows what would be synced without transferring
- `photos-sync backup --reset` clears all job state from database for fresh start

**Setup Wizard (`--setup`)**
- Check for rclone and 1Password CLI availability via `which` command
- Validate 1Password credentials exist (B2 app key ID, app key, bucket name)
- Offer to CREATE a new 1Password item with a generated encryption password if none exists
- Test rclone crypt configuration with a small test write to verify encryption works end-to-end
- Configure rclone remotes if not already set up (base B2 remote + crypt overlay)
- Store destination configuration in `backup_destinations` table

**Credential Management**
- All credentials retrieved from 1Password via `op` CLI at runtime
- B2 credentials: application key ID, application key, bucket name
- Encryption password: generated during setup, stored in same 1Password item
- Never store credentials in config files, database, or rclone.conf directly

**Backup Execution**
- Use `rclone sync` with crypt backend for client-side encryption
- Source paths come from `BACKUP_IMMICH_PATH` environment variable in `.env`
- One job per source directory (library, upload, profile, backups, dam/data)
- Jobs execute sequentially based on priority field
- Use `--stats` flag for progress reporting, parsed to update database
- Single `backup.log` file overwritten each run (intentional simplicity)

**Job State Management**
- Jobs stored in `backup_jobs` table with status: PENDING, RUNNING, COMPLETED, INTERRUPTED, FAILED
- Track bytes_total, bytes_transferred, files_transferred, transfer_speed
- Stale detection: if last_update exceeds rclone's `--stats` interval (default 1 minute), mark as INTERRUPTED
- Resume by re-running rclone sync (rclone handles partial file resume internally)
- Retry count and max retries (default 3) for automatic retry of failed jobs

**Status Command**
- Show last backup time per destination
- Show current job progress if running (from database, not live logs)
- Show total bytes backed up, completion percentage
- Report any stale or failed jobs with error messages

## Visual Design
No visual assets provided.

## Existing Code to Leverage

**Tracker.swift migration pattern**
- Use `runMigrations()` pattern with `getColumnNames()` helper to check column existence
- Add new tables with `CREATE TABLE IF NOT EXISTS`
- Add columns with `ALTER TABLE ADD COLUMN` wrapped in existence check
- Create indexes with `CREATE INDEX IF NOT EXISTS`

**Config.swift .env loading pattern**
- Use `findDAMDirectory()` pattern to locate .env file
- Parse key=value pairs, skip comments and empty lines
- Add new env var: `BACKUP_IMMICH_PATH` for Immich data directory path

**StatusCommand.swift ArgumentParser pattern**
- Implement `AsyncParsableCommand` protocol
- Use `CommandConfiguration` with commandName and abstract
- Load config with `Config.load()`, initialize Tracker
- Use `@Flag` and `@Option` decorators for command arguments

**main.swift command registration**
- Add `BackupCommand.self` to subcommands array in `CommandConfiguration`

## Out of Scope
- AWS Glacier/S3 destinations (architecture supports future addition, not implemented)
- Multiple simultaneous backup destinations running in parallel
- Backup scheduling/automation (use external cron/launchd)
- Live log streaming in status command
- Log file rotation or retention policies
- Restore command (separate future spec)
- Backing up thumbs/ directory (regeneratable)
- Backing up encoded-video/ directory (regeneratable)
- Incremental backup strategies beyond rclone's built-in sync
- Bandwidth throttling (use rclone's built-in --bwlimit externally if needed)
