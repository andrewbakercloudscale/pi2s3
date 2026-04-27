# Changelog

All notable changes to pi2s3 are documented here.

---

## [1.9.0] — 2026-04-27

### Added

- **`extras/diagnose-restore.sh`** — 10-section diagnostic script. Covers: (1) power/voltage with decoded throttle state, per-rail voltages, CPU temp, dmesg undervoltage event count; (2) hardware — CPU, memory, NVMe presence + SMART, EEPROM boot order, watchdog device; (3) restore log completeness — per-log pass/fail, monitor CSV with undervoltage-per-interval analysis, download speed; (4) WiFi — saved connections, active SSID + signal, password special-character encoding check; (5) corporate proxy/firewall — env vars, `/etc/environment`, iptables/nftables output rules; (6) internet + AWS — 10-ping packet loss to gateway/8.8.8.8/1.1.1.1, HTTPS TCP checks, S3 bucket access, STS identity; (7) active restore processes + taskset affinity; (8) boot config — SD card and NVMe cmdline.txt with PARTUUID cross-check (verifies `root=PARTUUID=` matches an actual attached block device, prints exact `sed` fix command if not); (9) recent kernel messages; (10) S3 manifest JSON validation — downloads the latest manifest, validates JSON with `jq`, detects malformed fields (the silent `dd`-vs-partclone fallback bug), shows detected `backup_type`, and prints the `sed` auto-repair command.
- **`extras/recover-sd-boot.sh`** — Mac-side recovery script for a Pi showing solid red LED (won't boot after restore). Auto-detects the SD card at `/Volumes/bootfs`; shows and diagnoses `cmdline.txt`; restores from `cmdline.txt.bak` if the automatic backup is present; otherwise prints step-by-step options (USB NVMe adapter, fresh flash, manual PARTUUID lookup).
- **`cmdline.txt.bak` automatic backup** (`extras/post-restore-nvme-boot.sh`) — before editing `/boot/firmware/cmdline.txt`, the original is backed up to `cmdline.txt.bak`. Used by `recover-sd-boot.sh` to restore a working boot when the PARTUUID write fails.
- **`rootdelay=5` in `post-restore-nvme-boot.sh`** — added to `/boot/firmware/cmdline.txt` if not present; gives the NVMe PCIe link time to enumerate before the kernel searches for the root partition.
- **Hardware watchdog** (`pi-image-restore.sh`) — opens `/dev/watchdog` (with `/dev/watchdog0` fallback for Pi OS Trixie where systemd holds the primary device) and kicks it every 30 s during restore. On hang, the watchdog fires a hardware reboot.
- **Background system monitor** (`pi-image-restore.sh`) — samples network bytes, CPU idle %, free memory, and throttle state every 10 s during restore. Saves CSV to `/var/log/pi2s3-restore-monitor-TIMESTAMP.log`. `diagnose-restore.sh` parses this to count undervoltage intervals and compute average download speed.
- **Persistent restore log** (`pi-image-restore.sh`) — `exec > >(tee /var/log/pi2s3-restore-TIMESTAMP.log)` at startup; log survives reboots and is analysed by `diagnose-restore.sh`.
- **Restore pinned to 1 CPU** (`pi-image-restore.sh`) — `taskset` pins the entire restore pipeline to the last CPU; OS, SSH, and network stack keep all remaining cores. Reduces sustained power draw, preventing undervoltage on marginal PSUs.
- **`CLONE_SUFFIX` variable** (`extras/post-restore-nvme-boot.sh`) — configurable hostname suffix when cloning a Pi. Default is `-2` (e.g. `andrewninja-pi-5` → `andrewninja-pi-5-2`). Set `NEW_HOSTNAME` for an exact name or `CLONE_SUFFIX=-qa` for a suffix override. Prevents hostname conflicts without manual post-boot renaming.
- **`config.env` auto-exported to subprocesses** (`pi-image-restore.sh`) — `set -a; source config.env; set +a` exports every variable (including `NEW_HOSTNAME`) so `--post-restore` scripts inherit them without any extra plumbing.

### Fixed

- **Undervoltage abort too aggressive** (`pi-image-restore.sh`) — `0x50005` (undervoltage + throttle) is a common boot-time transient that clears within seconds. Aborting immediately blocked restores on healthy PSUs with a brief startup dip. Changed to: warn with banner → sleep 10 s → re-check; only abort if still undervolted after 10 s.
- **Manifest JSON malformation causes silent `dd` fallback** (`pi-image-restore.sh`) — a `"extra_device": ,` field in the manifest (produced by `pi-image-backup.sh` when `BACKUP_EXTRA_DEVICE` is unset) caused `jq` to fail silently, `BACKUP_TYPE` defaulted to `"dd"`, and the partclone backup was streamed raw to the device producing an unbootable NVMe. Fixed: auto-repair with `sed 's/:\s*,/: null,/g'` applied before all parsing; grep regex fallback added to `get_manifest_field()`.
- **IRQ pinning glob** (`pi-image-restore.sh`) — glob was too broad; narrowed to only CPU-bound IRQs.
- **Watchdog device held by systemd** (`pi-image-restore.sh`) — Pi OS Trixie's systemd holds `/dev/watchdog` exclusively. Added `exec 3>` probe loop that falls back to `/dev/watchdog0` automatically.

---

## [1.8.0] — 2026-04-24

### Added

- **`--rate-limit <speed>` flag** (`pi-image-restore.sh`) — caps the uncompressed byte rate into `partclone` (applied after `gunzip`, directly controlling NVMe write throughput). Prevents PCIe watchdog resets on Pi 5 + NVMe combinations that crash under sustained writes. Example: `--rate-limit 10m` = 10 MB/s to the NVMe. Requires `pv`.
- **`extras/post-restore-nvme-boot.sh`** — post-restore script that wires up NVMe as the boot target without any manual steps: (1) swaps the original Pi's SD card PARTUUID in `/etc/fstab` with the new Pi's SD PARTUUID; (2) updates `/boot/firmware/cmdline.txt` `root=` to point at the restored NVMe root partition. Pass `NEW_HOSTNAME=<name>` to rename the clone in the same step. Full error handling and per-step logging.
- **`extras/cloud-init/`** — Pi OS Bookworm cloud-init templates for a DR/QA Pi (`user-data`, `network-config`, `meta-data`). Enables a factory-fresh Pi to SSH-ready in ~1 min with all pi2s3 dependencies installed and the repo cloned.
- **`extras/DR-quickstart.md`** — end-to-end DR runbook: flash SD → cloud-init → AWS credentials → restore → NVMe boot → Cloudflare tunnel.
- **ionice + nice on partclone pipeline** (`pi-image-restore.sh`) — `ionice -c 3 nice -n 19` prevents the restore from starving the SSH session's network stack on memory-constrained machines.
- **fsck after every restored ext partition** (`pi-image-restore.sh`) — runs `e2fsck -f -y` on each ext2/3/4 partition immediately after `partclone` completes, clearing the dirty-journal state left by a live backup. Exit codes 0/1 = clean, 2 = warn, 4+ = error logged.

### Fixed

- **`jq` not listed as a required dependency** (`pi-image-restore.sh`) — `get_manifest_field()` uses `jq` to parse `backup_type` from the manifest. Without `jq`, it returned empty and `BACKUP_TYPE` silently fell back to `"dd"`, causing every partclone-format restore to write a single raw partition to the whole device with no partition table. Added explicit `command -v jq || die` check and added `jq` to the cloud-init package list.
- **`--rate-limit` applied to compressed stream** (`pi-image-restore.sh`) — the rate-limiting `pv -L` was positioned before `gunzip`, limiting the compressed byte rate. After expansion (~1.3–1.4× for typical ext4 data), the actual NVMe write rate exceeded the specified limit by 30–40%. Moved the rate-limiting `pv` to after `gunzip` for direct write-rate control; the progress-display `pv` remains before `gunzip`.
- **Invalid JSON in manifest when `extra_device` is unset** (`pi-image-backup.sh`) — the manifest heredoc produced `"extra_device": ,` when `BACKUP_EXTRA_DEVICE` was unset, failing `python3`/`jq` JSON parsing on every standard (single-device) backup. Pre-compute `EXTRA_DEVICE_JSON` with a `null` fallback before the heredoc.
- **`fstype` not passed to partition restore loop** (`pi-image-restore.sh`) — the Python manifest parser only extracted `name`, `tool`, `key`, `compressed_bytes`. Added `fstype` so the new post-restore fsck can identify which partitions are ext2/3/4.

### Changed

- **SUDO_USER credential forwarding** (`pi-image-restore.sh`) — when run as `sudo`, AWS CLI looked in `/root/.aws/` instead of the real user's home directory. Now detects `SUDO_USER` via `getent passwd` and sets `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` to the real user's paths.
- **`jq` added to cloud-init package list** (`extras/cloud-init/user-data`) — `jq` is now installed alongside `partclone pigz pv python3 git awscli` so the restore script works out of the box on a freshly cloud-init-provisioned Pi.
- **Next-steps section** (`pi-image-restore.sh`) — updated to distinguish NVMe-on-SD-card boot setups from standalone device restores, and to reference `post-restore-nvme-boot.sh`.

---

## [1.7.1] — 2026-04-23

### Fixed

- **`break` in resize function** (`pi-image-restore.sh`) — `break` with no enclosing loop skipped the fsck abort guard and allowed `resize2fs` to run on a filesystem with uncorrectable errors. Replaced with `return 1`.
- **Spurious `cat |` before heredoc** (`install.sh`) — `cat | sudo tee file <<HEREDOC` made `cat` read from the terminal while `tee` read from the heredoc. Removed the `cat |`.
- **`A && ok || die/warn` patterns** (`install.sh`, `test-recovery.sh`, `website/restore`) — the `||` branch could fire even on success if the intermediate command returned non-zero. All nine occurrences rewritten as explicit `if/else`.
- **Startup error messages going to stdout** (`pi-image-backup.sh`, `pi-image-restore.sh`, `extras/fleet-deploy.sh`) — fatal early-exit errors now correctly go to stderr.
- **Dead variable `VERIFY_DATE_FOR_VERIFY`** (`pi-image-restore.sh`) — removed unused declaration.
- **Unused `REPO_DIR`** (`extras/build-recovery-usb.sh`, `extras/build-netboot-image.sh`) — removed unused variable (left over from earlier draft).
- **Unused `SCRIPT_DIR`** (`extras/build-recovery-usb.sh`, `extras/build-netboot-image.sh`) — after `REPO_DIR` was removed, `SCRIPT_DIR` also became unused and was removed.
- **`ls *.img` for filename assignment** (`extras/build-recovery-usb.sh`, `extras/build-netboot-image.sh`) — replaced with `find -maxdepth 1 -name '*.img'` to handle filenames with spaces.
- **Hardcoded absolute paths** (`deploy-pi.sh`) — `PI_KEY`, `PI_LOCAL`, `PI_CF_HOST`, `PI_CF_USER` now default to sensible values and can be overridden via environment variables.
- **Missing `set -e` explanation** (`extras/cf-tunnel-watchdog.sh`, `extras/fpm-saturation-monitor.sh`) — added comment explaining why `-e` is intentionally omitted (both scripts must survive partial failures and continue recovery/monitoring).
- **SC2015 in fleet-deploy arg parser** (`extras/fleet-deploy.sh`) — `[[ -z ... ]] && x="$1" || { error; exit }` rewritten as `if/else`.
- **40-line DONE comment block** (`pi-image-backup.sh`) — removed completed-feature notes from script header; history is in CHANGELOG.
- **Boot firmware compressed size not logged** (`pi-image-backup.sh`) — `FW_COMPRESSED_HUMAN` was computed but never used; now logged alongside SHA256.
- **Arithmetic `$` on array index** (`pi-image-backup.sh`) — removed unnecessary `$` on array subscript inside `$((...))`.
- **`trap` double-quote SC2064** (`extras/setup-netboot.sh`) — added `shellcheck disable` comment explaining expand-at-set-time is intentional.
- **`sed` for indentation** (`extras/setup-netboot.sh`) — replaced `echo | sed 's/^/    /'` with a plain `while read` loop.
- **SC1083 false positive on `@{u}`** (`push.sh`) — added `shellcheck disable` comment; `@{u}` is a git upstream refspec, not a bash brace expansion.

### Added

- **`QUALITY-TODO.md`** — full code quality analysis report (21 findings) with per-script health scores. All items now resolved.

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


