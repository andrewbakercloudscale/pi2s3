# Changelog

All notable changes to pi2s3 are documented here.

---

## [1.3.0] — 2026-04-16

### Added

- **Client-side encryption** (`BACKUP_ENCRYPTION_PASSPHRASE`) — GPG AES-256 encrypts each partition image before upload. Passphrase stored in `config.env` only; never written to S3. Restore script auto-detects encryption from manifest `"encryption"` field and decrypts inline; prompts interactively if passphrase not in `config.env`.
- **Post-upload auto-verify** (`BACKUP_AUTO_VERIFY=true`, on by default) — after every backup, re-lists S3 to confirm all uploaded files are non-zero. Result included in ntfy success notification.
- **Pre/post backup hooks** (`PRE_BACKUP_CMD` / `POST_BACKUP_CMD`) — shell commands run before and after partition imaging. For non-Docker setups (native MariaDB, nginx, php-fpm, etc.). `on_exit` crash trap calls `POST_BACKUP_CMD` on failure so services always restart. Aborts backup cleanly if `PRE_BACKUP_CMD` exits non-zero.
- **`--cost` flag** — lists per-date S3 sizes and calculates estimated monthly cost by storage class. Reads directly from S3; no re-download needed.
- **`--help` flag** — prints full usage to stdout for both `pi-image-backup.sh` and `pi-image-restore.sh`.
- **GitHub Actions CI** — `bash -n` syntax check on all 6 scripts on every push and pull request to `main`.
- **Website: Security & Reliability section** — 7 cards covering client-side encryption, bandwidth throttle, auto-verify, preflight health checks, stale backup alert, crash-safe Docker restart, and pre/post hooks.
- **Website: version badge** in footer linking to GitHub releases.
- **README: CI badge**, multi-Pi section, `--cost`/`--help` in flags table, `BACKUP_ENCRYPTION_PASSPHRASE` config, encryption passphrase security warning, list/verify sections with example output, pre/post backup hooks section.

### Fixed

- Branding: `ntfy_send "Pi MI backup complete"` → `ntfy_send "pi2s3 backup complete"` in `pi-image-backup.sh`.
- `pi-image-restore.sh` comments and log statements updated from "Pi MI" → "pi2s3".
- README: "Pi MI" → "pi2s3" in comparison table and prose.

---

## [1.2.0] — 2026-04-16

### Added

- **SHA-256 checksums in-flight** — each partition's compressed stream is forked via `tee >(sha256sum ...)` and hashed simultaneously with upload; no re-download required. Checksums stored per partition in the manifest JSON. `--verify` prints stored checksums for spot-checking.
- **Partial / file-level restore** (`--extract`) — streams a partition from S3, restores into a sparse temp file via loop device, mounts read-only, and copies the requested path to `./pi2s3-extract-<date>/`. No target device needed. Options: `--extract <path>`, `--partition <name>`, `--date <YYYY-MM-DD>`.
- **Cross-device restore** (`--resize`) — after restore, runs `growpart` + `resize2fs` (ext4) to expand the last partition to fill a larger device. Advisory message for xfs/btrfs.
- **Per-host S3 namespacing** — backups stored under `pi-image-backup/<hostname>/<date>/`. `pi-image-restore.sh` auto-discovers host prefixes; prompts if multiple exist. `--host` flag for explicit selection.
- **Stale backup alert** — `--stale-check` mode ntfys if the latest backup is older than `STALE_BACKUP_HOURS` (default: 25h). Installed as a daily cron by `install.sh` (`STALE_CHECK_ENABLED=true`). Catches silent cron failures.
- **Preflight health checks** — `preflight_health()` runs before Docker stop: checks for unhealthy/exited containers, free disk space (`PREFLIGHT_MIN_FREE_MB`), and recent I/O errors via `dmesg`. `PREFLIGHT_ABORT_ON_WARN=true` to abort on warnings (default: proceed).
- **Bandwidth throttle** — `AWS_TRANSFER_RATE_LIMIT` in `config.env` caps S3 upload speed via `pv -q -L <rate>` (e.g. `2m` = 2 MB/s). Gracefully skips if `pv` not installed or var unset.
- **Per-host retention** — `MAX_IMAGES_<hostname>=N` in `config.env` overrides `MAX_IMAGES` for a specific host (hyphens → underscores). Enables different retention windows per Pi in multi-Pi setups.
- **Failure ntfy alerts include last 10 log lines** — diagnose failures from the push notification without SSH.
- **Post-backup container safety check** — separate cron job ~30 min after backup verifies Docker came back up. Guards against mid-imaging crashes leaving containers stopped.
- **Website** — pi2s3 logo in hero; Prerequisites section with IAM policy; Troubleshooting section; partial-restore and --resize usage; andrewbaker.ninja nav link.

### Changed

- `test-recovery.sh --pre-flash` checks per-partition SHA-256 fields in manifest (replaces old single `device_sha256` field). Warns gracefully for backups that predate checksum support.

### Removed

- Dropped planned TODO(7) incremental backup — restore complexity outweighs cost savings at 3–5 GB/day compressed. Full images restore in one command with no history dependency.

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
