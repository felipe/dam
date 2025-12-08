# Task Breakdown: Backup Command

## Overview
Total Tasks: 9 Task Groups with ~50 subtasks

This feature adds a `photos-sync backup` command to backup Immich data to encrypted cloud storage (Backblaze B2), with resumable job tracking for large multi-terabyte backups.

## Task List

### Infrastructure Layer

#### Task Group 1: Database Schema and Migrations
**Dependencies:** None
**Complexity:** Medium

- [x] 1.0 Complete database layer for backup tracking
  - [x] 1.1 Write 4-6 focused tests for backup tables
    - Test backup_destinations table CRUD
    - Test backup_jobs table CRUD
    - Test job status transitions (PENDING -> RUNNING -> COMPLETED)
    - Test stale job detection query
  - [x] 1.2 Add `backup_destinations` table migration to Tracker.swift
    - Fields: id, name, type, bucket_name, remote_path, created_at, last_backup_at
    - Follow existing `runMigrations()` pattern with `getColumnNames()` helper
    - Use `CREATE TABLE IF NOT EXISTS` pattern
  - [x] 1.3 Add `backup_jobs` table migration to Tracker.swift
    - Fields: id, destination_id, source_path, status (PENDING/RUNNING/COMPLETED/INTERRUPTED/FAILED), bytes_total, bytes_transferred, files_total, files_transferred, transfer_speed, started_at, completed_at, last_update, error_message, retry_count, priority
    - Create indexes for status, destination_id, last_update
  - [x] 1.4 Add backup-related query methods to Tracker.swift
    - `createBackupDestination()` / `getBackupDestinations()` / `getBackupDestination(name:)`
    - `createBackupJob()` / `updateBackupJob()` / `getBackupJobs(destinationId:)`
    - `getActiveBackupJob()` / `markJobInterrupted()` / `markJobCompleted()`
    - `resetBackupJobs()` for --reset flag support
  - [x] 1.5 Add stale job detection method
    - Query jobs where `last_update` exceeds configured threshold (default 60 seconds)
    - Return jobs that should be marked as INTERRUPTED
  - [x] 1.6 Ensure database layer tests pass
    - Run ONLY the 4-6 tests written in 1.1
    - Verify migrations work on fresh and existing databases

**Acceptance Criteria:**
- All 4-6 database tests pass
- Migrations are idempotent (can run multiple times safely)
- Backup destination and job CRUD operations work correctly
- Stale detection query returns correct results

---

#### Task Group 2: Configuration
**Dependencies:** None (can run parallel with Task Group 1)
**Complexity:** Small

- [x] 2.0 Complete configuration updates
  - [x] 2.1 Write 2-3 focused tests for backup config loading
    - Test BACKUP_IMMICH_PATH loading from .env
    - Test BACKUP_STATS_INTERVAL loading with default
    - Test missing backup config graceful handling
  - [x] 2.2 Add backup config fields to Config.swift
    - `backupImmichPath: String?` - path to Immich data directory
    - `backupStatsInterval: Int` - rclone stats interval in seconds (default 60)
    - `backupMaxRetries: Int` - max retry count for failed jobs (default 3)
    - Follow existing .env loading pattern from lines 30-41
  - [x] 2.3 Update .env.example with backup variables
    - Add `BACKUP_IMMICH_PATH=/path/to/immich/data`
    - Add `BACKUP_STATS_INTERVAL=60`
    - Add `BACKUP_MAX_RETRIES=3`
    - Add comments explaining each variable
  - [x] 2.4 Ensure config tests pass
    - Run ONLY the 2-3 tests written in 2.1

**Acceptance Criteria:**
- Config.swift loads backup-related env vars
- .env.example documents all new variables
- Missing BACKUP_IMMICH_PATH returns nil gracefully (not error)

---

### Core Infrastructure

#### Task Group 3: External Tool Wrappers
**Dependencies:** Task Group 2 (needs Config)
**Complexity:** Medium

- [x] 3.0 Complete external tool wrapper implementations
  - [x] 3.1 Write 4-6 focused tests for tool wrappers
    - Test rclone availability check (which rclone)
    - Test rclone sync command construction
    - Test 1Password CLI availability check (which op)
    - Test 1Password item read parsing
  - [x] 3.2 Create RcloneWrapper.swift
    - Path: `swift/Sources/PhotosSyncLib/Backup/RcloneWrapper.swift`
    - Method: `checkInstalled() async -> Bool` using `which rclone`
    - Method: `sync(source:destination:dryRun:statsInterval:) async throws -> AsyncStream<SyncProgress>`
    - Method: `configureRemote(name:type:config:) async throws`
    - Method: `testConnection(remote:) async throws -> Bool`
    - Use Foundation `Process` for subprocess execution
    - Parse `--stats` output for progress updates (bytes transferred, speed, ETA)
  - [x] 3.3 Create SyncProgress struct for rclone output parsing
    - Fields: bytesTransferred, bytesTotal, filesTransferred, filesTotal, speed, eta
    - Parse from rclone `--stats` JSON output
  - [x] 3.4 Create OnePasswordCLI.swift
    - Path: `swift/Sources/PhotosSyncLib/Backup/OnePasswordCLI.swift`
    - Method: `checkInstalled() async -> Bool` using `which op`
    - Method: `checkSignedIn() async -> Bool` using `op account get`
    - Method: `getItem(vault:title:) async throws -> [String: String]`
    - Method: `createItem(vault:title:fields:) async throws`
    - Method: `generatePassword(length:) async throws -> String`
    - Parse JSON output from op CLI
  - [x] 3.5 Add error types for external tool failures
    - `BackupError.rcloneNotInstalled`
    - `BackupError.rcloneConfigFailed(String)`
    - `BackupError.onePasswordNotInstalled`
    - `BackupError.onePasswordNotSignedIn`
    - `BackupError.onePasswordItemNotFound(String)`
  - [x] 3.6 Ensure wrapper tests pass
    - Run ONLY the 4-6 tests written in 3.1
    - Tests should mock subprocess execution where appropriate

**Acceptance Criteria:**
- RcloneWrapper can check installation and run sync
- OnePasswordCLI can check installation and read/create items
- Progress parsing extracts correct values from rclone output
- All wrapper tests pass (14 tests passing)

---

#### Task Group 4: Backup Destination Protocol and B2 Implementation
**Dependencies:** Task Groups 1, 2, 3
**Complexity:** Medium

- [x] 4.0 Complete backup destination abstraction
  - [x] 4.1 Write 4-5 focused tests for backup destinations
    - Test B2Destination initialization
    - Test credential retrieval from 1Password
    - Test rclone remote configuration
    - Test test-write verification
  - [x] 4.2 Create BackupDestination protocol
    - Path: `swift/Sources/PhotosSyncLib/Backup/BackupDestinationProtocol.swift`
    - Protocol defines: `name`, `type`, `configure()`, `validate()`, `testWrite()`, `backup(source:dryRun:onProgress:)`
    - Include `DestinationType` enum: `.b2` (future: `.glacier`, `.s3`)
  - [x] 4.3 Create B2Destination.swift implementing protocol
    - Path: `swift/Sources/PhotosSyncLib/Backup/B2Destination.swift`
    - Load credentials from 1Password: applicationKeyId, applicationKey, bucketName, encryptionPassword
    - Configure rclone B2 remote with `rclone config`
    - Configure rclone crypt overlay for client-side encryption
    - Implement backup using `rclone sync` with crypt remote
  - [x] 4.4 Add 1Password item structure for B2 credentials
    - Item title: configurable (default "Immich Backup B2")
    - Fields: application_key_id, application_key, bucket_name, encryption_password
    - Document expected item structure in code comments
  - [x] 4.5 Implement test-write verification
    - Create small test file in source directory
    - Upload to destination with encryption
    - Verify file exists in destination
    - Clean up test file
  - [x] 4.6 Ensure destination tests pass
    - Run ONLY the 4-5 tests written in 4.1 (12 tests passing)

**Acceptance Criteria:**
- BackupDestination protocol allows future destination types
- B2Destination correctly retrieves credentials from 1Password
- rclone crypt configuration works for encrypted backups
- Test-write confirms encryption works end-to-end

---

### Orchestration Layer

#### Task Group 5: Backup Manager and Job Execution
**Dependencies:** Task Groups 1, 4
**Complexity:** Large

- [x] 5.0 Complete backup orchestration logic
  - [x] 5.1 Write 5-7 focused tests for BackupManager
    - Test job creation for each source directory
    - Test sequential job execution by priority
    - Test progress tracking and database updates
    - Test interruption detection and INTERRUPTED status
    - Test resume behavior (re-running rclone sync)
    - Test retry logic for failed jobs
  - [x] 5.2 Create BackupJob.swift model
    - Path: `swift/Sources/PhotosSyncLib/Backup/BackupJob.swift`
    - Struct representing a backup job with all fields from database
    - Status enum: `.pending`, `.running`, `.completed`, `.interrupted`, `.failed`
    - Priority for execution order (library > upload > profile > backups > dam/data)
  - [x] 5.3 Create BackupManager.swift
    - Path: `swift/Sources/PhotosSyncLib/Backup/BackupManager.swift`
    - Method: `runBackup(destination:dryRun:force:) async throws`
    - Method: `getStatus() -> BackupStatus`
    - Method: `createJobsForSource(path:destination:) throws -> [BackupJob]`
    - Orchestrate job execution sequentially by priority
    - Update job progress in database from rclone stats
  - [x] 5.4 Implement stale job detection and recovery
    - Check for jobs with `last_update` exceeding stats interval
    - Mark stale jobs as INTERRUPTED
    - Resume INTERRUPTED jobs on next run (unless --force)
    - Warn user about stale jobs, offer --force to ignore
  - [x] 5.5 Implement retry logic
    - Track retry_count per job
    - Auto-retry FAILED jobs up to max_retries
    - Capture error_message for failed jobs
    - Skip jobs that exceed max_retries
  - [x] 5.6 Implement logging
    - Single `backup.log` file overwritten each run
    - Log path: `data/backup.log`
    - Log start time, source paths, progress, errors, completion
  - [x] 5.7 Ensure backup manager tests pass
    - Run ONLY the 5-7 tests written in 5.1

**Acceptance Criteria:**
- Jobs execute sequentially in priority order
- Progress is tracked in database during execution
- Stale jobs are detected and marked INTERRUPTED
- Retry logic works for failed jobs
- Logging captures execution details

---

### CLI Layer

#### Task Group 6: Backup Command Implementation
**Dependencies:** Task Groups 2, 5
**Complexity:** Medium

- [x] 6.0 Complete CLI command implementation
  - [x] 6.1 Write 4-6 focused tests for BackupCommand
    - Test --check flag validates prerequisites
    - Test --status flag shows database state
    - Test --reset flag clears job state
    - Test --dry-run flag prevents actual transfer
    - Test --to flag selects specific destination
  - [x] 6.2 Create BackupCommand.swift
    - Path: `swift/Sources/PhotosSync/Commands/BackupCommand.swift`
    - Implement `AsyncParsableCommand` protocol (follow StatusCommand.swift pattern)
    - Use `CommandConfiguration` with commandName "backup" and abstract
  - [x] 6.3 Implement command flags and options
    - `@Flag(name: .long, help: "Check prerequisites")` check: Bool
    - `@Flag(name: .long, help: "Run setup wizard")` setup: Bool
    - `@Option(name: .long, help: "Destination name")` to: String?
    - `@Flag(name: .long, help: "Show backup status")` status: Bool
    - `@Flag(name: .long, help: "Force backup ignoring stale jobs")` force: Bool
    - `@Flag(name: .long, help: "Show what would be synced")` dryRun: Bool
    - `@Flag(name: .long, help: "Clear all job state")` reset: Bool
  - [x] 6.4 Implement --check prerequisite validation
    - Check rclone installed via RcloneWrapper.checkInstalled()
    - Check 1Password CLI installed via OnePasswordCLI.checkInstalled()
    - Check 1Password signed in via OnePasswordCLI.checkSignedIn()
    - Print clear status for each prerequisite
  - [x] 6.5 Implement --status subcommand
    - Show last backup time per destination
    - Show current job progress if running (from database)
    - Show total bytes backed up, completion percentage
    - Report any stale or failed jobs with error messages
  - [x] 6.6 Implement main backup execution flow
    - Load config and validate BACKUP_IMMICH_PATH set
    - Get or create destination (--to or default)
    - Check for stale jobs (warn unless --force)
    - Run BackupManager.runBackup()
    - Report completion or errors
  - [x] 6.7 Register BackupCommand in main.swift
    - Add `BackupCommand.self` to subcommands array
  - [x] 6.8 Ensure command tests pass
    - Run ONLY the 4-6 tests written in 6.1

**Acceptance Criteria:**
- All command flags work as documented
- --check validates all prerequisites
- --status shows database state (not live logs)
- Main backup flow executes jobs correctly
- Command is registered and accessible via `photos-sync backup`

---

#### Task Group 7: Setup Wizard
**Dependencies:** Task Groups 3, 4, 6
**Complexity:** Medium

- [x] 7.0 Complete interactive setup wizard
  - [x] 7.1 Write 3-4 focused tests for setup wizard
    - Test prerequisite checking flow
    - Test 1Password item creation
    - Test rclone remote configuration
    - Test test-write verification
  - [x] 7.2 Implement --setup flag handler in BackupCommand
    - Parse setup type: `--setup b2` (only b2 supported initially)
    - Validate type is supported
  - [x] 7.3 Implement B2 setup flow
    - Step 1: Check prerequisites (rclone, op CLI)
    - Step 2: Check for existing 1Password item
    - Step 3: If no item, prompt to create with generated encryption password
    - Step 4: Validate required fields present (key ID, key, bucket)
    - Step 5: Configure rclone B2 remote
    - Step 6: Configure rclone crypt overlay
    - Step 7: Run test-write verification
    - Step 8: Save destination to database
  - [x] 7.4 Implement 1Password item creation flow
    - Generate secure encryption password (32 chars)
    - Create item with all required fields
    - Prompt user to fill in B2 credentials manually
    - Wait for user confirmation, then validate
  - [x] 7.5 Add user prompts and confirmations
    - Use FileHandle.standardInput for interactive input
    - Clear prompts with [Y/n] format
    - Provide progress feedback during each step
  - [x] 7.6 Ensure setup wizard tests pass
    - Run ONLY the 3-4 tests written in 7.1

**Acceptance Criteria:**
- `photos-sync backup --setup b2` runs complete wizard
- Creates 1Password item if needed with generated password
- Configures rclone remotes correctly
- Test-write confirms encryption works
- Destination saved to database on successful setup

---

### Documentation Layer

#### Task Group 8: Documentation Updates
**Dependencies:** All other task groups
**Complexity:** Small

- [x] 8.0 Complete documentation
  - [x] 8.1 Update main README.md with backup command section
    - Add `photos-sync backup` to command list
    - Document prerequisites (rclone, 1Password CLI)
    - Document setup process
    - Document backup execution
    - Document status checking
  - [x] 8.2 Document all command flags in README
    - `--check` - validate prerequisites
    - `--setup b2` - run setup wizard
    - `--to <name>` - backup to specific destination
    - `--status` - show backup status
    - `--force` - ignore stale jobs
    - `--dry-run` - preview only
    - `--reset` - clear job state
  - [x] 8.3 Add backup architecture section
    - Explain client-side encryption via rclone crypt
    - Explain job tracking and resumability
    - Explain 1Password credential storage
    - List directories that are backed up
  - [x] 8.4 Add troubleshooting section
    - Stale job recovery
    - 1Password sign-in issues
    - rclone configuration debugging

**Acceptance Criteria:**
- README documents all backup functionality
- Prerequisites are clearly listed
- Setup process is step-by-step
- Troubleshooting covers common issues

---

## Test Coverage Summary

#### Task Group 9: Test Review and Gap Analysis
**Dependencies:** Task Groups 1-7
**Complexity:** Medium

- [x] 9.0 Review existing tests and fill critical gaps only
  - [x] 9.1 Review tests from Task Groups 1-7
    - Database layer: already have tests in BackupTracker.spec.swift (9 tests)
    - Config: already have tests in BackupConfig.spec.swift (4 tests)
    - Tool wrappers: already have tests in ToolWrappers.spec.swift (14 tests)
    - Destinations: already have tests in BackupDestination.spec.swift (12 tests)
    - Backup manager: already have tests in BackupManager.spec.swift (8 tests)
    - CLI command: already have tests in BackupCommand.spec.swift (16 tests)
    - Setup wizard: included in BackupCommand.spec.swift
    - Total existing: 50 tests
  - [x] 9.2 Analyze test coverage gaps for backup feature only
    - Identified gaps in integration workflows
    - Focus on backup feature requirements, not entire app
    - Prioritize integration tests over unit tests
  - [x] 9.3 Write up to 8 additional strategic tests if needed
    - Full backup workflow test (setup -> backup -> status)
    - Interrupted backup resume test
    - Multiple destination switching test
    - Error recovery and retry test
    - BackupStatus computed properties test
    - BackupJob extension methods test
    - getJobsToExecute with mixed states test
    - BackupJobPriority edge cases test
  - [x] 9.4 Run all backup feature tests
    - Run ONLY backup-related tests with `swift test --filter "Backup"`
    - All 58 backup tests pass
    - Verified all backup workflows work correctly

**Acceptance Criteria:**
- All backup feature tests pass (58 tests)
- Critical workflows covered (setup, backup, resume, status)
- 8 additional strategic integration tests added
- Test coverage focused exclusively on backup feature

---

## Execution Order

Recommended implementation sequence:

1. **Phase 1 - Foundation (Parallel)** - COMPLETED
   - Task Group 1: Database Schema (can start immediately)
   - Task Group 2: Configuration (can start immediately, independent)

2. **Phase 2 - Core Infrastructure** - COMPLETED
   - Task Group 3: External Tool Wrappers (needs Config)
   - Task Group 4: Backup Destinations (needs Wrappers)

3. **Phase 3 - Orchestration** - COMPLETED
   - Task Group 5: Backup Manager (needs DB + Destinations)

4. **Phase 4 - CLI** - COMPLETED
   - Task Group 6: Backup Command (needs Manager)
   - Task Group 7: Setup Wizard (needs Command structure)

5. **Phase 5 - Polish** - COMPLETED
   - Task Group 8: Documentation (after feature complete)
   - Task Group 9: Test Review (after all features)

---

## File Summary

New files to create:
- `swift/Sources/PhotosSyncLib/Backup/RcloneWrapper.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/OnePasswordCLI.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/BackupDestinationProtocol.swift` - CREATED (was BackupDestination.swift)
- `swift/Sources/PhotosSyncLib/Backup/B2Destination.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/BackupError.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/SyncProgress.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/BackupJob.swift` - CREATED
- `swift/Sources/PhotosSyncLib/Backup/BackupManager.swift` - CREATED
- `swift/Sources/PhotosSync/Commands/BackupCommand.swift` - CREATED

Test files created:
- `swift/Tests/PhotosSyncTests/Backup/BackupTracker.spec.swift` - CREATED (9 tests)
- `swift/Tests/PhotosSyncTests/Backup/BackupConfig.spec.swift` - CREATED (4 tests)
- `swift/Tests/PhotosSyncTests/Backup/ToolWrappers.spec.swift` - CREATED (14 tests)
- `swift/Tests/PhotosSyncTests/Backup/BackupDestination.spec.swift` - CREATED (12 tests)
- `swift/Tests/PhotosSyncTests/Backup/BackupManager.spec.swift` - CREATED (8 tests)
- `swift/Tests/PhotosSyncTests/Backup/BackupCommand.spec.swift` - CREATED (16 tests)
- `swift/Tests/PhotosSyncTests/Backup/BackupIntegration.spec.swift` - CREATED (8 tests)

Existing files to modify:
- `swift/Sources/PhotosSyncLib/Database/Tracker.swift` (add migrations and queries) - ALREADY DONE
- `swift/Sources/PhotosSyncLib/Config.swift` (add backup config fields) - ALREADY DONE
- `swift/Sources/PhotosSync/main.swift` (register BackupCommand) - DONE
- `.env.example` (add BACKUP_* variables) - ALREADY DONE
- `README.md` (add backup documentation) - DONE

---

## Technical Notes

### Database Migration Pattern
Follow existing pattern in Tracker.swift (lines 60-188):
```swift
private func runMigrations() throws {
    let columns = getColumnNames(table: "backup_jobs")
    if !columns.contains("new_column") {
        let sql = "ALTER TABLE backup_jobs ADD COLUMN new_column TEXT"
        // execute...
    }
}
```

### Subprocess Execution Pattern
Use Foundation Process for rclone/op CLI:
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["rclone", "sync", ...]
let pipe = Pipe()
process.standardOutput = pipe
try process.run()
```

### AsyncParsableCommand Pattern
Follow StatusCommand.swift (lines 6-10):
```swift
struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Backup Immich data to encrypted cloud storage"
    )
}
```

---

## Final Summary

**All 9 Task Groups Complete**

Total tests: 58 backup-related tests passing
- BackupTracker.spec.swift: 9 tests
- BackupConfig.spec.swift: 4 tests
- ToolWrappers.spec.swift: 14 tests
- BackupDestination.spec.swift: 12 tests
- BackupManager.spec.swift: 8 tests
- BackupCommand.spec.swift: 16 tests (includes setup wizard tests)
- BackupIntegration.spec.swift: 8 tests (strategic integration tests)

Documentation updated:
- README.md now includes comprehensive backup documentation
- All command flags documented
- Architecture section explains encryption, job tracking, credentials
- Troubleshooting section covers common issues
