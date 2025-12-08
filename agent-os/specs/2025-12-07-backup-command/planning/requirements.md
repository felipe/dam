# Spec Requirements: Backup Command

## Initial Description

Add a `photos-sync backup` command to backup Immich data to encrypted cloud storage (Backblaze B2, with architecture supporting future backends like Glacier/S3).

Critical requirements from raw idea:
- Local Immich has ~1TB of data that needs offsite backup
- Backups must be encrypted (client-side via rclone crypt + server-side)
- Large backups will be interrupted (network drops, sleep, restarts) and must resume gracefully

Key functionality:
- Check prerequisites (rclone, 1Password CLI)
- Get credentials from 1Password
- Configure rclone crypt for encryption
- Execute backup via rclone subprocess
- Track job state in tracker.db for resumable backups
- Support multiple destinations (B2 primary, Glacier/S3 future)

## Requirements Discussion

### First Round Questions

**Q1:** Where should backup job state be stored - add tables to existing tracker.db via migration, or separate backup.db?
**Answer:** Use existing tracker.db - add backup tables via existing migration pattern

**Q2:** Should the Immich data path be hardcoded, configurable via .env, or passed as command argument?
**Answer:** Should come from `BACKUP_IMMICH_PATH` in `.env`, not hardcoded

**Q3:** For `--setup` wizard scope: should it just validate 1Password/rclone credentials exist, or also test encryption/upload with a small test file?
**Answer:** BOTH - validate credentials exist AND test rclone/encryption with a small test write

**Q4:** Should `backup status` show live log output from running jobs, or just database state and progress?
**Answer:** Just database state and progress (not live log output)

**Q5:** For 1Password credential management: should the command offer to create a new 1Password item during setup with a generated encryption password?
**Answer:** Offer to create one during `--setup` with generated encryption password

**Q6:** How should stale job detection work - fixed time threshold, or based on rclone's `--stats` interval?
**Answer:** Based on rclone's `--stats` interval

**Q7:** For log files: single file overwritten each run, or timestamped files? How long to retain?
**Answer:** Single file overwritten each run, intentional for simplicity

**Q8:** Any explicit exclusions beyond what's in the GitHub issue?
**Answer:** None additional beyond what's in the GitHub issue

### Existing Code to Reference

**Similar Features Identified:**
- Feature: Tracker migrations - Path: `/Users/felipe/Projects/felipe/dam/swift/Sources/PhotosSyncLib/Database/Tracker.swift`
  - Use `runMigrations()` pattern with `getColumnNames()` helper
  - Add columns with `ALTER TABLE ADD COLUMN` wrapped in existence check
  - Create indexes with `CREATE INDEX IF NOT EXISTS`

- Feature: Config .env loading - Path: `/Users/felipe/Projects/felipe/dam/swift/Sources/PhotosSyncLib/Config.swift`
  - Use `findDAMDirectory()` pattern to locate .env
  - Parse key=value pairs, skip comments and empty lines
  - New env var: `BACKUP_IMMICH_PATH`

- Feature: ArgumentParser commands - Path: `/Users/felipe/Projects/felipe/dam/swift/Sources/PhotosSync/Commands/StatusCommand.swift`
  - Implement `AsyncParsableCommand` protocol
  - Use `CommandConfiguration` with commandName and abstract
  - Load config with `Config.load()`, initialize Tracker

## Visual Assets

### Files Provided:
No visual assets provided.

## Requirements Summary

### Functional Requirements

**Core Backup Workflow:**
- Execute `rclone sync` with crypt backend for client-side encryption
- Source: Immich data directory (from `BACKUP_IMMICH_PATH` in .env)
- Destination: Backblaze B2 (primary), architecture for future Glacier/S3
- Resume interrupted backups gracefully using rclone's built-in resume capability
- Track job state in tracker.db for status reporting

**Setup Wizard (`--setup`):**
- Check for rclone and 1Password CLI availability
- Validate 1Password credentials exist (B2 app key, bucket name)
- Offer to create new 1Password item with generated encryption password
- Test rclone crypt configuration with small test write to verify encryption works
- Configure rclone remotes if not already set up

**Status Command (`backup status`):**
- Show database state: last backup time, bytes transferred, completion status
- Show current progress if backup is running (from database, not live logs)
- Report stale jobs based on rclone's `--stats` interval

**Credential Management:**
- Retrieve B2 credentials from 1Password via CLI
- Store encryption password in 1Password (generated during setup)
- Never store credentials in config files or database

### Database Schema (via migration)

New table(s) in tracker.db:
- `backup_jobs`: Track backup job state (id, started_at, completed_at, status, bytes_total, bytes_transferred, files_transferred, destination, error_message)
- Job status values: running, completed, failed, interrupted

### Configuration

New .env variables:
- `BACKUP_IMMICH_PATH`: Path to Immich data directory to backup

### Reusability Opportunities

- Tracker migration pattern from `Tracker.swift` for adding backup tables
- Config loading pattern from `Config.swift` for new env vars
- AsyncParsableCommand pattern from `StatusCommand.swift` for command structure
- Use Foundation `Process` for subprocess management (rclone execution)

### Scope Boundaries

**In Scope:**
- `photos-sync backup` command with encrypted B2 backup
- `photos-sync backup --setup` wizard
- `photos-sync backup status` subcommand
- Job tracking in tracker.db
- 1Password integration for credentials
- Resumable backup support
- Single log file per run (overwritten)
- Stale job detection based on rclone stats interval

**Out of Scope:**
- AWS Glacier/S3 destinations (future enhancement)
- Multiple simultaneous backup destinations
- Backup scheduling/automation (use cron/launchd externally)
- Live log streaming in status command
- Log file rotation or retention
- Restore command (separate future spec)

### Technical Considerations

- Use rclone subprocess for actual backup execution
- rclone crypt backend for client-side encryption
- 1Password CLI (`op`) for credential retrieval
- Leverage rclone's built-in resume capability for interrupted transfers
- Database tracks job metadata, rclone handles transfer state
- Stale detection: if last update exceeds rclone `--stats` interval (e.g., 1 minute), mark as potentially stale
