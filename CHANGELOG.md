# Changelog

All notable changes to pi2s3 are documented here.

---

## [Unreleased]

### Added

- **SHA-256 checksums in-flight** — each partition's compressed stream is forked via `tee >(sha256sum ...)` and uploaded simultaneously; no re-download required. Checksums stored per partition in the manifest JSON. `--verify` now prints stored checksums for manual spot-checking.
- **Partial / file-level restore** (`--extract`) — new flag on `pi-image-restore.sh`. Streams the partition from S3, restores it into a sparse temp file via a loop device, mounts it read-only, and copies the requested path to `./pi2s3-extract-<date>/`. No physical target device needed. Useful for recovering individual files, directories, or configs. Options:
  - `--extract <path>` — path within the filesystem to extract (e.g. `/home/pi`, `/etc`)
  - `--partition <name>` — which partition to mount (default: largest non-vfat partition = root fs)
  - `--date <YYYY-MM-DD>` — backup date (default: latest)
- **Failure ntfy alerts include last 10 log lines** — diagnose backup failures directly from the push notification without needing to SSH in.
- **Website** — new Prerequisites section with IAM least-privilege policy; Troubleshooting section; partial-restore usage examples; footer links to andrewbaker.ninja and cloudtorepo.com.

### Changed

- `test-recovery.sh --pre-flash` now checks for per-partition SHA-256 checksums in the manifest (replacing the old single `device_sha256` field). Warns gracefully for backups that predate checksum support.

---

## [1.1.0] — 2026-04-13

### Added

- **Rename: pi-mi → pi2s3** throughout codebase, cron, log paths, and install script.
- **pi2s3.com website** — dark-mode SPA covering architecture, quickstart, restore steps, watchdog, and coverage table.
- **RECOVERY.md** — full disaster-recovery runbook: hardware checklist, bootstrap SD card flashing from macOS, restore procedure, post-boot verification, NVMe-only recommendation.
- **`-F` flag on partclone** — allows cloning mounted partitions (all NVMe partitions remain mounted during backup). Eliminates the need to unmount partitions separately.
- **Docker stops for full imaging duration** — Docker is stopped before the first partition starts and restarted after the last partition finishes, ensuring full write consistency across all partitions in a multi-partition backup.
- **Recovery safety net** — if the backup fails, the on-exit handler attempts to restart Docker so containers don't stay down.
- **Verified uploads** — after each S3 `cp`, the script confirms the S3 object exists and is non-zero before continuing.
- **Always-notify on exit** — `on_exit` trap fires for any non-zero exit, ensuring a failure notification is always sent even if the script crashes mid-run.
- **`install.sh` improvements** — creates log file before cron install; `--status` warns if log file is missing.

---

## [1.0.0] — 2026-03-xx

Initial release.

### Features

- Block-level nightly backup of Raspberry Pi to S3 using partclone + pigz
- Streaming upload: no local temp file (direct Pi → S3)
- Partition table saved as sfdisk dump and restored first
- Boot firmware partition on separate SD card backed up separately
- Manifest JSON with hostname, Pi model, OS, partition layout, sizes, duration
- `pi-image-restore.sh` — interactive and non-interactive full restore
- `test-recovery.sh` — pre-flash validation and post-boot verification
- `pi2s3-watchdog.sh` — three-phase Cloudflare tunnel + Docker self-healing monitor
- S3 lifecycle policy + STANDARD_IA storage class
- ntfy.sh push notifications (success, failure, watchdog events)
- `install.sh` — full setup, watchdog install, upgrade, status, uninstall
- `--dry-run` mode for safe testing
- Legacy dd format support (reads old `.img.gz` backups)
