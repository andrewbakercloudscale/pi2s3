# Changelog

All notable changes to pi2s3 are documented here.

---

## [1.7.0] — 2026-04-23

### Added

- **`--post-restore <script>` flag** (`pi-image-restore.sh`) — after a full partclone restore completes, mounts the restored root partition read-write, exports `RESTORE_ROOT`, and runs the user-supplied script. Enables restoring to a second Pi and immediately customising it (hostname, Cloudflare tunnel credentials, `.env` variables, SSH host keys) before the first boot. Template at `extras/post-restore-example.sh`.
- **Recovery USB image builder** (`extras/build-recovery-usb.sh`) — builds a bootable Raspberry Pi OS Lite ARM64 image with `partclone`, `pigz`, `pv`, AWS CLI v2, and the pi2s3 repo pre-installed. On first boot the Pi auto-logs in, prompts for S3 bucket and AWS credentials if not yet configured, and launches the restore wizard. Supports x86_64 build hosts via `qemu-user-static`.
- **Recovery launcher** (`extras/recovery-launcher.sh`) — first-boot restore launcher used by the recovery USB image. Creates a minimal `config.env` from interactive prompts, runs `aws configure`, then hands off to `pi-image-restore.sh`.
- **GitHub Actions: Build Recovery USB Image** (`.github/workflows/release-recovery-usb.yml`) — manual `workflow_dispatch` to build the recovery USB image and publish it as a GitHub Release tagged `recovery-usb/YYYY-MM-DD`.
- **Pi 5 HTTP netboot** (`extras/setup-netboot.sh`) — configures Pi 5 EEPROM boot order to include HTTP boot (`BOOT_ORDER` entry `7`) pointing at `boot.pi2s3.com`. Modes: `(no args)` adds HTTP as fallback after NVMe; `--force` sets HTTP first for immediate recovery; `--disable` removes HTTP; `--show` prints current EEPROM config.
- **Netboot image builder** (`extras/build-netboot-image.sh`) — extracts the Pi kernel from Pi OS Lite, builds a minimal initramfs (Pi OS base + partclone + AWS CLI + pi2s3), and writes `config.txt` and `cmdline.txt`. Optionally uploads to S3 with `--upload`.
- **GitHub Actions: Build Netboot Image** (`.github/workflows/release-netboot.yml`) — manual workflow to build netboot boot files and upload to S3, or save as a GitHub Actions artifact.
- **Terraform: boot.pi2s3.com** (`extras/terraform/boot-infrastructure/`) — creates a private S3 bucket, CloudFront OAC, CloudFront distribution with `viewer_protocol_policy = allow-all` (required for Pi HTTP boot), ACM certificate (us-east-1, DNS validation), and IAM user `pi2s3-netboot-ci` with write-only access for CI uploads. Outputs ACM validation CNAMEs for Cloudflare and GitHub Actions secrets. `README.md` includes full manual AWS Console walkthrough as an alternative to Terraform.
- **Fleet deployment** (`extras/fleet-deploy.sh`) — reads a CSV manifest of Pis (`name,host,date,device,post_restore_script`), SSHes into each recovery-mode Pi, copies `config.env` and the per-Pi post-restore script, then runs `pi-image-restore.sh` non-interactively. Supports `--parallel` (all Pis simultaneously), `--dry-run`, `--only <name>`, `--no-resize`. Per-Pi logs saved to `fleet-deploy-logs-<timestamp>/`. Summary table on completion.
- **Fleet example** (`extras/fleet-example/`) — example `fleet.csv` manifest and `post-restore/classroom.sh` template that auto-derives the hostname from the last octet of the Pi's IP address and clears SSH host keys for per-Pi uniqueness.

### Fixed

- **CI syntax check** — `.github/workflows/ci.yml` was hardcoded to check `cf-tunnel-watchdog.sh` at the repo root. After the file moved to `extras/`, CI failed with "No such file or directory". Fixed by replacing the static list with dynamic grep-based discovery: any `.sh` file with a bash shebang anywhere in the repo is checked automatically.
- **`release-recovery-usb.yml` parse error** — invalid GitHub Actions expression `${{ steps.image.outputs.name %.xz }}` used bash parameter expansion syntax inside `${{ }}`, causing "No jobs were run". Fixed by computing `name_img` (`.xz`-stripped filename) as a separate step output.

### Changed

- **Docs** — README new sections: `--post-restore`, Recovery USB, HTTP netboot, Fleet deployment. RECOVERY.md: "faster alternatives" note at Step 2 pointing to recovery USB and netboot. Website: new "Go further" section with four feature cards; restore section updated with three recovery-mode options.

---

## [1.6.0] — 2026-04-22

### Added

- **One-liner installer** (`curl -sL pi2s3.com/install | bash`) — bootstrap script at `pi2s3.com/install` detects Pi model and architecture, installs git if missing, clones the repo (or pulls latest if already installed), and hands off to `install.sh`. Enables zero-prerequisite install from any Pi with internet access.
- **Bucket auto-create** — `install.sh` now distinguishes `NoSuchBucket` errors from credential errors. If the bucket doesn't exist, offers to create it with `aws s3 mb` (default: yes). Handles the `LocationConstraint` requirement for all regions except `us-east-1`.
- **First backup prompt** — after a successful dry-run, `install.sh` asks "Run a real backup now? [Y/n]". Removes the need to remember `--force` after install.
- **`--iam-policy` flag** — `bash install.sh --iam-policy` prints the minimum IAM policy with the bucket name substituted from `config.env`. Shown as a hint whenever AWS access fails.
- **`iam-policy.json`** — policy file included in the repo. Minimum permissions: `s3:CreateBucket`, `s3:ListBucket`, `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:PutLifecycleConfiguration`, `s3:GetLifecycleConfiguration`.
- **Support matrix** — documented tested/expected/unsupported combinations of Pi hardware, storage, and OS in README.
- **Shared library extraction** (`lib/log.sh`, `lib/aws.sh`, `lib/containers.sh`) — eliminates duplicate `log()`/`die()`/`aws_cmd()`/`find_db_container()`/`read_container_db_password()` definitions across scripts.
- **`main()` guards** — all scripts now use `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` so they can be safely sourced for testing.
- **`push.sh`** — one-command push to GitHub + deploy to Pi with `--no-deploy` option.
- **`deploy-pi.sh`** — LAN-first SSH pattern (tries `andrew-pi-5.local` directly, falls back to Cloudflare tunnel).

### Changed

- **ntfy is now optional** — `NTFY_URL` is no longer required. Installer prompt accepts Enter to skip. `ntfy_send()` is a no-op when `NTFY_URL` is empty. `config.env.example` defaults to blank.
- **32-bit arch guard** — `install.sh` now exits immediately on `armv7l`/`armv6l` with a clear error message instead of downloading the wrong AWS CLI binary and failing mid-install.
- **`get_manifest_field()` in `pi-image-restore.sh`** — replaced fragile `grep -o | cut` parsing with `jq -r ".field // empty"`.

### Fixed

- 32 code-review findings across all scripts: unquoted variables, missing `pipefail`, insecure temp files, `local` variable leaks, errors written to stdout, missing dependency checks.

---

## [1.5.1] — 2026-04-21

### Fixed

- **Orphaned-lock false positives (self-referential PROCESSLIST query)** — `fpm-saturation-monitor.sh` and `db_kill_orphaned_locks()` detected their own `SELECT ... WHERE INFO LIKE '%pi2s3-lock%'` queries as orphaned locks. MariaDB includes the querying connection itself in `information_schema.PROCESSLIST`, and the WHERE clause literal contains the string "pi2s3-lock", so each check matched itself. Result: ntfy "Orphaned backup lock killed" alerts fired every 30 min with incrementing connection IDs even when no backup was running. Fix: narrowed pattern to `'%/* pi2s3-lock */%'` (comment delimiters are present in the actual backup lock SQL but not in the WHERE clause text) and added `AND TIME > 5` (real locks have been running for minutes; detection queries complete in milliseconds).

---

## [1.5.0] — 2026-04-21

### Added

- **FPM auto-restart** (`FPM_AUTO_RESTART=true`) — `fpm-saturation-monitor.sh` now automatically restarts the WordPress container when the saturation threshold is hit, instead of alerting and waiting for manual intervention. Runs on the host cron (not WP-Cron), so it fires even when PHP-FPM is fully exhausted.
  - `FPM_AUTO_RESTART=false` (default) — alert only, no automatic action
  - `FPM_AUTO_RESTART=true` — `docker restart <FPM_WP_CONTAINER>` fires automatically after threshold, with ntfy confirmation
  - Before restarting, kills any orphaned `pi2s3-lock` process from inside the DB container (see fix below)
  - Sends a separate `type=restarted` callback to the CloudScale Devtools plugin
  - Alert message updated: when auto-restart is on, says "Auto-restarting now" instead of "SSH and run: docker restart"
- **`FPM_RESTART_COOLDOWN`** — minimum seconds between auto-restarts (default: `1200` / 20 min). Prevents restart loops if saturation recurs immediately after a restart.
- **Pre-commit hook on Pi** — `install.sh --upgrade` now installs a `.git/hooks/pre-commit` that blocks direct commits on the Pi, with a message pointing to the Mac → deploy workflow. Refreshed on every deploy.
- **`config.env.example`**: full PHP-FPM saturation monitor section added (was missing entirely).
- **Website**: new PHP-FPM saturation monitor section documenting auto-restart, orphaned lock detection, and plugin integration.

### Fixed

- **`db_unlock()` orphaned lock root cause** — killing the host-side `docker exec` wrapper process (`kill $_DB_LOCK_PID`) did not terminate the `mariadb` client running inside the container. The keepalive `SLEEP(86400)` connection survived, holding FTWRL and causing "Orphaned backup lock" ntfy alerts after every successful backup. Fix: `docker exec <container> pkill -9 -f pi2s3-lock` is now called from inside the container before killing the wrapper. This closes the SLEEP connection cleanly.
- **FPM monitor false positives** — orphaned-lock detection in `fpm-saturation-monitor.sh` previously killed `pi2s3-lock` connections whenever found, including during active backups. Now checks `pgrep -f pi-image-backup.sh` first; if the backup is running, the lock is legitimate and is left alone.
- **`probe_stop()` double-zero syntax error** — `grep -c ... || echo 0` produced `"0\n0"` under `set -u` when the log file didn't exist (grep exits 1 on no match, triggering the fallback alongside the empty output). Fixed with `|| true` and `${var:-0}` expansion.
- **`db_kill_orphaned_locks()` unbound variable** — `local _ids` without initialisation crashed under `set -u`. Fixed with `local _ids=""`.

### Changed

- `FPM_RESTART_COOLDOWN` default is `1200` (20 min).

---

## [1.4.0] — 2026-04-16

### Added

- **Zero-downtime DB lock** (`DB_CONTAINER`) — replaces `STOP_DOCKER` for MariaDB/MySQL setups. Issues `FLUSH TABLES WITH READ LOCK` before imaging and `UNLOCK TABLES` after. All containers stay running throughout — only DB writes are blocked during the imaging window (~5–15 min). Same technique used by mariabackup/xtrabackup.
  - `DB_CONTAINER="auto"` — scans running containers for any image containing `mariadb` or `mysql`; falls back to `STOP_DOCKER` if none found
  - `DB_CONTAINER="pi_mariadb"` — explicit container name for deterministic setups
  - `DB_CONTAINER=""` with `DB_ROOT_PASSWORD` set — native (non-Docker) MariaDB/MySQL on localhost
  - `DB_ROOT_PASSWORD` auto-read from container environment if not explicitly set (`MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD`)
- **Site availability probe** — background curl loop that pings your site every `PROBE_INTERVAL` seconds (default: 60) while partclone runs. Each request is cache-busted (`?pi2s3t=<timestamp>`) and sent with `Cache-Control: no-cache` headers to bypass CDN and WP page cache.
  - `PROBE_LATEST_POST=true` — auto-discovers the latest WordPress post via REST API and probes that URL instead of the homepage, testing real dynamic content
  - Results logged and included in the ntfy success notification (e.g. `probe: 8/8 pass`)
- **`DB_LOCK` → `STOP_DOCKER` fallback** — if `db_lock()` fails (wrong password, no DB, etc.) the script automatically falls back to the standard Docker stop and continues the backup
- **Parallel partition imaging** — boot firmware partition (SD card) runs concurrently with the last NVMe partition. `BACKUP_EXTRA_DEVICE` partitions run concurrently with the entire boot-device imaging. Both use separate physical buses so reads don't contend. Implemented via `image_to_s3()` helper that works identically inline or backgrounded.
- **`BACKUP_EXTRA_DEVICE` implemented** — was documented in `config.env.example` but never coded. Now fully functional: enumerates partitions on the extra device, images them in background parallel with boot device, adds results to manifest under `extra_device_partitions`.
- **`image_to_s3()` helper function** — extracted from inline imaging code. Handles the full `partclone | pigz | [gpg] | [pv] | aws s3 cp` pipeline and writes `sha256=…\ncompressed=…` to a temp result file. Eliminates code duplication across boot partitions, boot firmware, and extra device.
- **`db_kill_orphaned_locks()`** — called unconditionally before `db_lock()` on every run. Queries `information_schema.PROCESSLIST` for surviving `SELECT /* pi2s3-lock */ SLEEP(86400)` connections left by a previous crashed backup and kills them. Prevents the new backup from hanging when FTWRL blocks on a stale lock.
- **`fpm-saturation-monitor.sh`** — host cron script (every minute) that detects PHP-FPM worker pool exhaustion and alerts via ntfy.sh. Three mechanisms: HTTP probe, MariaDB long-running queries (>15 s from `wordpress` user), orphaned `pi2s3-lock` connections (killed immediately). Configurable: `FPM_SATURATION_THRESHOLD`, `FPM_PROBE_URL`, `FPM_ALERT_COOLDOWN`. Optional `FPM_CALLBACK_URL`/`FPM_CALLBACK_TOKEN` for CloudScale Devtools plugin reporting.

### Changed

- `STOP_DOCKER` is now the fallback path only; `DB_CONTAINER="auto"` (the default) attempts FTWRL lock first and falls back to Docker stop only if no DB is found
- **Early FTWRL release** — `db_unlock()` now called immediately after `sync` + `drop_caches`, before the partclone imaging loop. Site writes resume ~5 seconds into the backup window instead of after 15–30 minutes of imaging.
- **`db_unlock()` kill-before-wait** — `kill "${_DB_LOCK_PID}"` called before `wait` so unlock is always fast regardless of SQL KILL race outcome.
- `config.env.example`: DB lock section added before `STOP_DOCKER` with inline documentation; probe section added
- README + website hero updated to make clear zero-downtime is the default — no config change needed for MariaDB/MySQL Docker setups

### Fixed

- `probe_stop` is now always called (even when `_USE_DB_LOCK=false`) so the probe summary is always collected and logged.

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


