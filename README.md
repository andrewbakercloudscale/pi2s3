# pi2s3: Pi to S3

[![CI](https://github.com/andrewbakercloudscale/pi2s3/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewbakercloudscale/pi2s3/actions/workflows/ci.yml)

Block-level nightly backup of a Raspberry Pi to AWS S3. Restore a complete, bootable Pi to new hardware in one command. No manual setup, no secrets to re-enter, no git clones.

Think of it as an AMI for your Pi.

---

## How it works

```
BACKUP (runs on Pi nightly via cron)

  1. Quiesce the database
     ├─ MariaDB/MySQL detected → FLUSH TABLES WITH READ LOCK (zero downtime)
     └─ No DB detected        → stop Docker briefly (~10s)

  2. Sync filesystem  (instant)
     └─ flush dirty pages and drop caches

  3. Save partition table (GPT/MBR)
     └─ sfdisk -d /dev/nvme0n1  ──►  S3

  4. Image each partition with partclone  (~5–15 min for typical used data)
     └─ partclone reads the filesystem allocation map and skips
        unallocated blocks — only used data is transferred

     /dev/nvme0n1p1  ──►  partclone.ext4  ──►  pigz  ──►  aws s3 cp  ──►  S3
     /dev/nvme0n1p2  ──►  partclone.ext4  ──►  pigz  ──►  aws s3 cp  ──►  S3
     /dev/mmcblk0p1  ──►  partclone.vfat  ──►  pigz  ──►  aws s3 cp  ──►  S3
     (boot firmware)      partition-aware  parallel   streaming
                          clone           gzip       no local file

  5. Release DB lock / restart Docker  (writes resume)

  6. Upload manifest JSON (metadata: partitions, sizes, duration)


RESTORE (run on a Linux machine or another Pi)

  1. Download partition table from S3
     └─ sfdisk /dev/target  (recreates GPT layout)

  2. Restore each partition with partclone
     └─ S3  ──►  gunzip  ──►  partclone.restore  ──►  /dev/target

  3. Boot — root filesystem auto-expands to fill device on first boot
```

### Why partclone instead of dd?

`dd` reads every sector on the device regardless of whether it's used. On a 954 GB NVMe that's 28% full, `dd` reads **954 GB**. `partclone` reads the filesystem allocation bitmap and skips unallocated blocks — it reads **only the ~28 GB of used data**. Same result, 20× less data.

| | dd | partclone |
|---|---|---|
| Reads | every sector (used + empty) | used blocks only |
| Speed on 954GB NVMe (28% full) | ~90 min | ~5 min |
| S3 upload size | ~10 GB (compressed zeros) | ~3–5 GB |
| Restore | gunzip \| dd | partclone per partition |

### Zero-downtime mode (default for MariaDB/MySQL)

**No config needed.** The default `DB_CONTAINER="auto"` automatically scans for a running MariaDB/MySQL container. If found, pi2s3 uses `FLUSH TABLES WITH READ LOCK` (FTWRL) instead of stopping Docker. The lock is held only while `sync` and `drop_caches` complete (typically **under 10 seconds**), then released — DB writes resume while `partclone` images the partitions. Same technique as mariabackup/xtrabackup.

What happens automatically:
1. Kills any orphaned `pi2s3-lock` connections left by previous crashed backups (`db_kill_orphaned_locks`)
2. Scans running containers for any MariaDB/MySQL image
3. Auto-reads `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` from the container env
4. Issues `FLUSH TABLES WITH READ LOCK` via a persistent background connection
5. Runs `sync` + `drop_caches` to flush InnoDB dirty pages to disk (~5–10 seconds)
6. **Releases the lock** — all containers stay up for the full imaging window
7. Images all partitions with `partclone` — site serves reads *and* writes throughout
8. Reports probe pass/fail in the ntfy notification

InnoDB replays any redo log entries written during imaging on the next startup — fuzzy snapshots taken after lock release are fully consistent and bootable.

If no MariaDB/MySQL container is found (or the lock fails), the script falls back to `STOP_DOCKER=true` automatically and logs why.

A background **site availability probe** runs every `PROBE_INTERVAL` seconds (default: 60) during imaging — cache-busted requests to confirm the site stays up. `PROBE_LATEST_POST=true` (default) auto-discovers the latest WordPress post via REST API and probes real dynamic content instead of the homepage.

### Docker downtime (fallback)

If no MariaDB/MySQL container is detected, containers are stopped for the duration of partition imaging — typically **5–15 minutes** at 2am. Docker is restarted immediately after all partitions are imaged.

This is still far better than the old `dd` approach (60–90 minutes on a full NVMe), and gives a fully consistent image. On restore, no recovery step is needed.

---

## What gets backed up

| Data | Location | Covered |
|------|----------|---------|
| OS + kernel + packages | `/dev/nvme0n1` | ✅ |
| systemd services (cloudflared, watchdog) | `/dev/nvme0n1` | ✅ |
| Docker runtime + all images | `/dev/nvme0n1` | ✅ |
| Docker volumes (databases, uploads) | `/dev/nvme0n1` | ✅ |
| App config + `.env` files | `/dev/nvme0n1` | ✅ |
| SSH authorized keys | `/dev/nvme0n1` | ✅ |
| Cron jobs | `/dev/nvme0n1` | ✅ |
| GPT partition table | `/dev/nvme0n1` | ✅ |
| Boot firmware (`config.txt`, `cmdline.txt`) | `/boot/firmware` partition | ✅ |
| NVMe performance tuning | `/dev/nvme0n1` | ✅ |

> **Split-device setups**: if your Docker data root is on a *different physical device* than your OS (e.g. SD card boots, USB NVMe holds data), the backup script detects this and warns you. Set `BACKUP_EXTRA_DEVICE` in `config.env` to image both devices.

---

## Requirements

**On the Pi (backup):**
- Raspberry Pi OS (Bookworm or Trixie, 64-bit recommended)
- AWS CLI v2 — installed automatically by `install.sh`
- `partclone` — installed automatically by `install.sh`
- `pigz` — installed automatically by `install.sh` (parallel gzip, much faster than `gzip` on Pi 5's quad-core)
- AWS credentials — see [IAM policy](#aws-iam-policy) below

**For restore (Linux):**
- Linux machine with `sfdisk` (util-linux) and `partclone` installed
- AWS CLI v2 with read access to your bucket
- `python3` (for manifest parsing — standard on all modern Linux distros)
- `pv` optional for a live progress bar: `sudo apt install pv`
- `losetup` (util-linux) — required for `--extract` partial restores (standard on all Linux distros)

> **macOS note**: The restore script requires Linux because `sfdisk` and `partclone` are not available on macOS. The easiest approach: boot the new Pi from a minimal SD card, attach the target NVMe, SSH in, and run `pi-image-restore.sh` from there.

---

## Support matrix

| Hardware | OS | Status | Notes |
|---|---|---|---|
| Pi 5 + NVMe | Raspberry Pi OS Bookworm 64-bit | ✅ Tested | Reference platform |
| Pi 5 + SD card | Raspberry Pi OS Bookworm 64-bit | ✅ Tested | Slower upload (~90 min for full card) |
| Pi 4 + USB SSD | Raspberry Pi OS Bookworm 64-bit | ✅ Expected | Same kernel, same tools |
| Pi 4 + SD card | Raspberry Pi OS Bookworm 64-bit | ✅ Expected | |
| Pi 4 + NVMe (via HAT) | Raspberry Pi OS Bookworm 64-bit | ✅ Expected | HAT presents as `/dev/nvme0n1` |
| Pi 3B/3B+ | Raspberry Pi OS Bookworm 64-bit | ⚠️ Expected | Single-core pigz, no parallel imaging; expect 2–4× slower |
| Pi Zero 2W | Raspberry Pi OS Bookworm 64-bit | ⚠️ Expected | 512 MB RAM; 1-core compression; slow but functional |
| Any Pi + 32-bit OS (armv7l) | Raspberry Pi OS Legacy 32-bit | ⚠️ Limited | AWS CLI v2 has no official armv7l build; install may fail |
| Non-Raspberry Pi Linux (x86_64, etc.) | Any 64-bit Linux | 🔬 Untested | `partclone` must be installed manually; no Pi model detection |

**64-bit OS strongly recommended** — AWS CLI v2 has full aarch64 support; the 32-bit (armv7l) path requires manual AWS CLI install from source or a third-party build.

---

## AWS IAM policy

Minimum permissions required. Create a dedicated IAM user and attach this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:CreateBucket", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutLifecycleConfiguration", "s3:GetLifecycleConfiguration"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME"
    }
  ]
}
```

The policy file is included at [`iam-policy.json`](iam-policy.json). Print it with your bucket name substituted:

```bash
bash ~/pi2s3/install.sh --iam-policy
```

Apply via AWS CLI (one-time setup from any machine with IAM access):

```bash
# Create a dedicated user
aws iam create-user --user-name pi2s3

# Attach the policy (replace YOUR-BUCKET-NAME first)
aws iam put-user-policy --user-name pi2s3 \
  --policy-name pi2s3 \
  --policy-document file://iam-policy.json

# Generate credentials — paste output into 'aws configure' on the Pi
aws iam create-access-key --user-name pi2s3
```

---

## Quick start

### One-liner

```bash
curl -sL pi2s3.com/install | bash
```

SSH into your Pi and paste. Handles everything — installs dependencies, prompts for S3 bucket and region, configures cron, runs a dry-run test.

### Manual install

```bash
git clone https://github.com/andrewbakercloudscale/pi2s3.git ~/pi2s3
cd ~/pi2s3
bash install.sh
```

`install.sh` will:
- Prompt for your S3 bucket and AWS region (ntfy URL is optional)
- Write `config.env` (gitignored — never committed)
- Install `partclone`, `pigz`, and AWS CLI v2 if not present
- Verify AWS access to your bucket
- Set up S3 lifecycle policy
- Install the nightly cron job (2:00am by default)
- Run a `--dry-run` to confirm everything works

### 3. First backup

```bash
bash ~/pi2s3/pi-image-backup.sh --force
```

Takes 3–10 minutes depending on how full the device is and your network speed. You'll get an ntfy push notification when done (if `NTFY_URL` is configured).

---

## Configuration

All settings live in `config.env` (copy from `config.env.example`):

```bash
# Required
S3_BUCKET="your-bucket-name"
S3_REGION="us-east-1"

# Optional — push notifications via ntfy.sh (free hosted service)
NTFY_URL=""   # e.g. https://ntfy.sh/my-pi-backups  (blank = silent)

# Retention (default: 60 images)
MAX_IMAGES=60
# Per-host override (multi-Pi): hyphens → underscores in hostname
# MAX_IMAGES_my_pi_5=30

# AWS
AWS_PROFILE=""                 # blank = default profile or instance role
S3_STORAGE_CLASS="STANDARD_IA" # ~40% cheaper than STANDARD for backups

# Zero-downtime DB lock (recommended for MariaDB/MySQL setups)
DB_CONTAINER="auto"            # "auto" | "container-name" | "" (native)
DB_ROOT_PASSWORD=""            # blank = auto-read from container env

# Site availability probe (used with DB lock)
PROBE_URL=""                   # blank = auto-detect from CF_SITE_HOSTNAME
PROBE_LATEST_POST=true         # probe latest WP post via REST API instead of homepage
PROBE_INTERVAL=60              # seconds between probes

# Backup behaviour (fallback if DB_CONTAINER not set)
STOP_DOCKER=true               # stop Docker briefly for DB consistency (~10s)
DOCKER_STOP_TIMEOUT=30         # seconds to wait for containers to stop
CRON_SCHEDULE="0 2 * * *"     # 2:00am daily

# Bandwidth throttle (requires: sudo apt install pv)
AWS_TRANSFER_RATE_LIMIT=""     # e.g. "2m" = 2 MB/s, "500k" = 500 KB/s. blank = unlimited

# Client-side encryption (requires: sudo apt install gpg)
BACKUP_ENCRYPTION_PASSPHRASE="" # blank = S3 SSE only. Set to encrypt before upload.

# Pre/post backup hooks — stop/start non-Docker services around imaging
PRE_BACKUP_CMD=""              # e.g. "systemctl stop nginx php8.2-fpm mariadb"
POST_BACKUP_CMD=""             # e.g. "systemctl start mariadb php8.2-fpm nginx"

# Split-device (advanced)
BACKUP_EXTRA_DEVICE=""         # image a second device alongside boot (see below)

# Post-backup auto-verify
BACKUP_AUTO_VERIFY=true        # re-check S3 after every backup; result in ntfy notification

# Post-backup container safety check
POST_BACKUP_CHECK_ENABLED=true   # separate cron ~30 min after backup confirms containers came back up
POST_BACKUP_CHECK_SCHEDULE="30 2 * * *"  # adjust if backup typically runs longer than 30 min

# Pre-backup health checks
PREFLIGHT_ENABLED=true         # check container health, free disk, I/O errors before imaging
PREFLIGHT_MIN_FREE_MB=500      # abort if less than this much free disk space (MB)
PREFLIGHT_ABORT_ON_WARN=false  # false = warn but proceed; true = abort on any preflight warning

# Missed backup alert
STALE_CHECK_ENABLED=true       # daily cron checks S3 for a recent backup; ntfy if none found
STALE_CHECK_SCHEDULE="0 6 * * *"  # run well after backup window (default: 6am)
STALE_BACKUP_HOURS=25          # alert if no backup seen within this many hours

# Notifications
NTFY_LEVEL="all"               # "all" | "failure"
```

### Client-side encryption

Set `BACKUP_ENCRYPTION_PASSPHRASE` to encrypt every partition image with GPG AES-256 before upload. Even full S3 bucket access is useless without the passphrase.

```bash
# config.env
BACKUP_ENCRYPTION_PASSPHRASE="my-strong-passphrase"
```

Requires: `sudo apt install gpg`

The restore script reads the `encryption` field in the manifest and decrypts inline. If the passphrase is not in `config.env`, it prompts interactively.

> **Keep the passphrase safe.** If your Pi dies and you lose `config.env`, you cannot restore your backups. Store the passphrase in a password manager (1Password, Bitwarden, etc.) or write it down and store it offline — somewhere independent of the Pi. `config.env` also contains your AWS credentials; treat it like a secrets file.

### Cost estimate

At ~3–5 GB compressed per image (128 GB NVMe, ~25% full):

| Retention | S3 storage | Monthly cost (STANDARD_IA) |
|-----------|-----------|----------------------------|
| 7 images  | ~25 GB    | <$1/month                  |
| 30 images | ~120 GB   | ~$2/month                  |
| 60 images | ~240 GB   | ~$3/month                  |

Costs vary by region. `af-south-1` (Cape Town) is slightly higher than `us-east-1`.

---

## Backup script

```
pi-image-backup.sh [options]

  --force           Skip the duplicate-check (run even if today's backup exists)
  --dry-run         Show what would happen without uploading anything
  --setup           Create S3 lifecycle policy (run once after install)
  --list            List all backups in S3 with size and hostname
  --verify          Verify latest S3 backup files exist and are non-zero
  --verify=DATE     Verify specific date (YYYY-MM-DD)
  --stale-check     Ntfy alert if latest backup is older than STALE_BACKUP_HOURS
  --cost            Show S3 storage used and estimated monthly cost
  --no-stop-docker  Skip Docker stop (for daytime test runs with no downtime)
  --help            Show usage
```

SHA-256 checksums are computed in-flight during upload via `tee >(sha256sum ...)` — the compressed stream forks to the hash and S3 simultaneously with no re-download. Stored per partition in the manifest.

Failure ntfy alerts include the last 10 lines of the backup log for immediate triage without needing to SSH in.

Each backup creates a dated folder in S3:
```
s3://your-bucket/pi-image-backup/
  2026-04-14/
    partition-table-20260414_020045.sfdisk   ← GPT layout (applied first on restore)
    nvme0n1p1-20260414_020045.img.gz         ← partclone image, partition 1
    nvme0n1p2-20260414_020045.img.gz         ← partclone image, partition 2
    mmcblk0p1-boot-fw-20260414_020045.img.gz ← boot firmware (if on separate device)
    manifest-20260414_020045.json            ← metadata
```

The manifest records hostname, Pi model, OS, partition layout, sizes, duration, storage class, and **SHA-256 checksums** computed in-flight during upload (no re-download needed). The `--verify` flag checks all files listed in the manifest exist and are non-zero in S3, and prints the stored checksums.

Each partition entry in the manifest includes:
```json
{
  "name": "nvme0n1p2",
  "fstype": "ext4",
  "tool": "partclone.ext4",
  "size_bytes": 127363883008,
  "compressed_bytes": 2987654321,
  "sha256": "e3b0c44298fc1c149afb...",
  "key": "pi-image-backup/2026-04-16/nvme0n1p2-20260416_020045.img.gz"
}
```

Old images beyond `MAX_IMAGES` are deleted automatically.

### List backups

See what's in S3 with sizes and hostnames:

```bash
bash ~/pi2s3/pi-image-backup.sh --list
```

Output:
```
  [1] 2026-04-16  4.2G compressed (my-pi-5)
  [2] 2026-04-15  4.1G compressed (my-pi-5)
  [3] 2026-04-14  4.0G compressed (my-pi-5)

  Total: 3 backup(s)
```

### Verify a backup

Check that all files listed in the manifest exist and are non-zero in S3. Prints the stored SHA-256 checksums. Runs against the latest backup unless a date is specified:

```bash
# Verify latest
bash ~/pi2s3/pi-image-backup.sh --verify

# Verify a specific date
bash ~/pi2s3/pi-image-backup.sh --verify=2026-04-15
```

Output:
```
  OK  nvme0n1p1-20260415_020045.img.gz (512M)
  OK  nvme0n1p2-20260415_020045.img.gz (3.7G)
  OK  partition-table (1234 bytes)

Checksums (SHA-256 of compressed upload):
  e3b0c44298fc1c149afb4c8996fb92427ae41e4649b934ca495991b7852b855
  a87ff679a2f3e71d9181a67b7542122c04521ead5f5a64afe10c2b7d64dd5c6

VERIFY OK. All backup files present in S3.
```

This is the same check `BACKUP_AUTO_VERIFY=true` runs automatically after each backup. Use `--verify` to re-check at any time — after a suspected S3 issue, before a planned restore, or as part of a monthly audit.

---

## Restore script

```
pi-image-restore.sh [options]

  --list                      List all available backups
  --date YYYY-MM-DD           Use a specific backup (default: latest)
  --device /dev/...           Target device for full restore
  --yes                       Skip confirmation prompts
  --resize                    Expand last partition to fill device after restore
  --host <hostname>           Select a specific host's backups (multi-Pi setups)
  --extract <path>            Extract a file or directory from a backup (Linux only)
  --partition <name>          Partition to mount for --extract (default: largest non-boot)
  --verify /dev/...           Verify a flashed device against S3 manifest (dd format)
```

---

## Restore to a new Pi

> **Full step-by-step runbook:** [RECOVERY.md](RECOVERY.md) — the document to open when your Pi is dead and you need to restore from scratch. Covers hardware requirements, bootstrap SD flashing from macOS, restore procedure, and post-boot verification.

### Step 1 — Validate (Mac)

Before touching anything, confirm the S3 image is ready:

```bash
bash ~/pi2s3/test-recovery.sh --pre-flash
```

Checks AWS access, confirms image exists and is non-zero, reads the manifest, estimates flash time, prints the restore command.

### Step 2 — Flash (Linux or Pi)

> **Requires Linux** — `sfdisk` and `partclone` are not available on macOS.
>
> **On macOS**: boot the new Pi from a minimal SD card, attach the target NVMe,
> SSH in, clone the repo, and run from there.

```bash
bash ~/pi2s3/pi-image-restore.sh
```

Interactive prompts let you pick the backup date and target device. Streams directly from S3 — no local download needed.

Or restore a specific date non-interactively:
```bash
bash ~/pi2s3/pi-image-restore.sh --date 2026-04-13 --device /dev/nvme0n1 --yes
```

Install `pv` for a live progress bar:
```bash
sudo apt install pv
```

What happens during restore:
1. Partition table downloaded from S3 and applied to target device with `sfdisk`
2. Each partition streamed from S3 → `gunzip` → `partclone.restore` with inline checksum verification
3. Boot firmware partition restored separately (if it was on a separate device)

### Step 2b — Partial restore (recover a single file or directory)

No target device needed. Streams the partition from S3, mounts it via a loop device (Linux kernel feature: treats a regular file as a block device), and copies the requested path to `./pi2s3-extract-<date>/`.

```bash
# Recover /home/pi from the latest backup
bash ~/pi2s3/pi-image-restore.sh --extract /home/pi

# Recover /etc from a specific date
bash ~/pi2s3/pi-image-restore.sh --extract /etc --date 2026-04-16

# Specify which partition (default: largest non-boot partition = root fs)
bash ~/pi2s3/pi-image-restore.sh --extract /var/lib/docker --partition nvme0n1p2
```

**Linux only** — requires `losetup` (standard in `util-linux`) and `mount`. Only works with partclone-format backups (all backups since v1.1).

### Step 3 — Boot

Insert the storage into the new Pi and power on. Raspberry Pi OS automatically expands the root filesystem to fill the device on first boot.

**Clear the old SSH host key on your Mac** (the restored Pi has the same key as the original):
```bash
ssh-keygen -R raspberrypi.local
ssh-keygen -R <ip-address>
ssh pi@raspberrypi.local
```

### Step 4 — Validate (new Pi)

```bash
bash ~/pi2s3/test-recovery.sh --post-boot
```

Checks: `config.env` present and configured, filesystem expansion, NVMe mount, Docker + all containers, Cloudflare tunnel, cron jobs, MariaDB tables, memory, load. PASS/FAIL/WARN per check.

### Full walkthrough

```bash
bash ~/pi2s3/test-recovery.sh --guide
```

Prints the complete step-by-step recovery guide.

---

## Test recovery script

```
test-recovery.sh --pre-flash [--date YYYY-MM-DD]
test-recovery.sh --post-boot
test-recovery.sh --guide
```

**`--pre-flash`** (Mac) — run before flashing:
- Validates `config.env` and AWS connectivity
- Confirms image file exists and is non-zero size
- Reads manifest (hostname, Pi model, OS, device, compressed size)
- Estimates flash time
- Prints go/no-go with exact restore command

**`--post-boot`** (new Pi) — run after first boot:
- OS version, kernel, uptime
- Filesystem expansion (is root partition using the full device?)
- NVMe mounted at `/mnt/nvme`
- Docker daemon + all containers running
- Docker data-root on correct device
- Cloudflare tunnel active
- Cron jobs present (pi2s3 backup + app-layer backup)
- MariaDB responding + has tables
- HTTP check on localhost
- Memory and load
- SSH host key reminder

Exit code `0` = all passed. Exit code `1` = one or more failures.

---

## Split-device setups

If your Pi boots from SD card but stores Docker data on a separate NVMe or USB drive, the backup script detects this during preflight:

```
WARNING: Docker data is on a DIFFERENT device than boot!
  Boot device:   /dev/mmcblk0 (will be imaged)
  Docker data:   /dev/sda     (NOT in this image)
```

Fix by adding to `config.env`:
```bash
BACKUP_EXTRA_DEVICE="/dev/sda"
```

The script will then image both devices, storing the second as `pi-image-extra-sda-<timestamp>.img.gz` alongside the boot image.

---

## Pre/post backup hooks

If you run services **outside of Docker** — native MySQL, MariaDB, nginx, php-fpm, or any other systemd service — use `PRE_BACKUP_CMD` and `POST_BACKUP_CMD` to stop them before imaging and restart them after.

### Native WordPress example

```bash
# config.env
STOP_DOCKER=false   # no Docker on this Pi
PRE_BACKUP_CMD="systemctl stop nginx php8.2-fpm mariadb"
POST_BACKUP_CMD="systemctl start mariadb php8.2-fpm nginx"
```

Imaging takes 5–15 minutes. MariaDB/nginx are down only for that window.

### How it works

- `PRE_BACKUP_CMD` runs **after preflight, before imaging**. If it exits non-zero the backup is aborted immediately — no partial image is taken.
- `POST_BACKUP_CMD` runs **after imaging completes**. The `on_exit` crash trap also calls it if the script dies mid-imaging, so your services always come back up even on failure.
- `STOP_DOCKER=true` and hooks can coexist: Docker stops first, then `PRE_BACKUP_CMD`, then imaging, then `POST_BACKUP_CMD`, then Docker restarts.

Any shell command or script path works:

```bash
PRE_BACKUP_CMD="/usr/local/bin/my-pre-backup.sh"
POST_BACKUP_CMD="/usr/local/bin/my-post-backup.sh"
```

---

## Multi-Pi setups

pi2s3 supports multiple Pis sharing a single S3 bucket. Each Pi stores its backups under `pi-image-backup/<hostname>/` automatically — no config needed.

### Per-host retention

Add per-host retention overrides in `config.env` (replace hyphens in hostname with underscores):

```bash
MAX_IMAGES=60           # global default
MAX_IMAGES_my_pi_5=30  # override for host "my-pi-5"
MAX_IMAGES_pi_zero=7   # override for host "pi-zero"
```

### Restoring from a specific Pi

If multiple Pi hostnames exist in the bucket, `pi-image-restore.sh` prompts you to choose. Or specify directly:

```bash
bash ~/pi2s3/pi-image-restore.sh --host my-pi-5
```

### Stale check per Pi

The `--stale-check` cron runs on each Pi independently and checks only that Pi's own backups under its hostname prefix.

### Cost estimate

See actual S3 usage and estimated monthly cost for the current host:

```bash
bash ~/pi2s3/pi-image-backup.sh --cost
```

---

## Cloudflare tunnel watchdog

An optional self-healing monitor that runs every 5 minutes as a root cron job. If your site or Cloudflare tunnel goes down, it automatically recovers through three escalating phases before rebooting the Pi as a last resort.

### How it works

```
Every 5 min (root cron)
  ↓
Check 1: Any Docker containers stopped?
Check 2: HTTP probe on localhost — 5xx or connection failure?
Check 3: cloudflared ha_connections > 0? (if metrics endpoint available)
  ↓
All OK → log and exit
  ↓
Something down:

Phase 1 (attempts 1–4, 0–20 min)
  → start stopped containers + restart cloudflared
  → verify, notify recovery or continue

Phase 2 (attempts 5–8, 20–40 min)
  → docker compose down/up (full stack restart) + cloudflared
  → verify, notify recovery or continue

Phase 3 (attempt 9+, 40+ min)
  → dump diagnostics to /var/log/pi2s3-watchdog-prediag.log
  → reboot Pi (max once per 6 hours — rate-limited)
  → if rate-limited: "manual needed" alert sent, exit without reboot
```

Push notifications via ntfy at every stage: first failure, each phase escalation, recovery, and stuck-down alerts.

### Enable

In `config.env`:
```bash
CF_WATCHDOG_ENABLED=true
CF_SITE_HOSTNAME="your-site.com"   # used in push notification titles
CF_HTTP_PORT=80                    # local port to probe
CF_COMPOSE_DIR=""                  # auto-detected, or set explicitly
```

Then install:
```bash
bash ~/pi2s3/install.sh --watchdog
```

Or set `CF_WATCHDOG_ENABLED=true` before running the initial `install.sh` and it installs automatically as part of setup.

### Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `CF_WATCHDOG_ENABLED` | `false` | Set `true` to install |
| `CF_SITE_HOSTNAME` | hostname | Used in ntfy notification titles |
| `CF_HTTP_PORT` | `80` | Local port for HTTP probe |
| `CF_HTTP_PROBE_PATH` | `/` | URL path to probe |
| `CF_METRICS_URL` | `http://127.0.0.1:20241/metrics` | cloudflared metrics endpoint |
| `CF_COMPOSE_DIR` | auto-detect | Path to `docker-compose.yml` |
| `CF_PHASE1_MAX` | `4` | Attempts before full stack restart |
| `CF_PHASE2_MAX` | `8` | Attempts before Pi reboot |
| `CF_REBOOT_MIN_INTERVAL` | `21600` | Seconds between reboots (6 hours) |

> **cloudflared metrics**: only checked if the endpoint is reachable. Enable in your cloudflared config with `metrics: localhost:20241`. If not configured, the watchdog skips the tunnel connection check and relies on Docker + HTTP checks only.

### Commands

```bash
# Install / reinstall watchdog
bash ~/pi2s3/install.sh --watchdog

# Manual test run
sudo /usr/local/bin/pi2s3-watchdog.sh

# Live log tail
sudo journalctl -t pi2s3-watchdog -f

# View today's watchdog activity
sudo journalctl -t pi2s3-watchdog --since today

# View pre-reboot diagnostics (if a watchdog reboot occurred)
sudo cat /var/log/pi2s3-watchdog-prediag.log
```

---

## PHP-FPM saturation monitor

When all PHP-FPM workers are exhausted, WordPress serves 504 errors — but WP-Cron itself is also stuck, so any cron-based alerting goes silent at the worst moment. `fpm-saturation-monitor.sh` runs as a **host cron** (not inside Docker), so it fires regardless of PHP-FPM state.

### How it works

Three checks run every minute:

| Check | Condition | Action |
|-------|-----------|--------|
| HTTP probe | `curl` to `FPM_PROBE_URL` times out or returns 5xx | Increment saturation counter |
| Long DB queries | `> 15 s` queries from `wordpress` user in `PROCESSLIST` | Increment saturation counter |
| Orphaned backup lock | `pi2s3-lock` sleep connection in `PROCESSLIST` | Kill immediately + alert (once per 30 min) |

After `FPM_SATURATION_THRESHOLD` consecutive saturated checks (default: 3) an ntfy alert fires. Set `FPM_AUTO_RESTART=true` to automatically restart the WordPress container instead of waiting for manual intervention — an ntfy notification confirms the restart with a cooldown between attempts. A recovery notification fires when the site returns to normal.

### Install

```bash
# 1. Add to crontab on the Pi host
crontab -e
# Paste: * * * * * /home/pi/pi2s3/fpm-saturation-monitor.sh 2>/dev/null
```

Add to `~/pi2s3/config.env`:
```bash
# ── PHP-FPM Saturation Monitor ──────────────────────────────────────────────
FPM_SATURATION_THRESHOLD=3       # consecutive saturated checks before alerting
FPM_PROBE_URL=http://localhost:8082/
FPM_PROBE_TIMEOUT=5
FPM_WP_CONTAINER=pi_wordpress
FPM_DB_CONTAINER=pi_mariadb
FPM_ALERT_COOLDOWN=1800          # seconds between repeat alerts (30 min)
FPM_AUTO_RESTART=false           # true = restart container automatically on saturation
FPM_RESTART_COOLDOWN=1200        # seconds between auto-restarts (default: 20 min)
# Optional — report events back to CloudScale Devtools plugin:
# FPM_CALLBACK_URL=https://yoursite.com/wp-admin/admin-ajax.php
# FPM_CALLBACK_TOKEN=<token from Debug AI tab>
```

### Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `FPM_SATURATION_THRESHOLD` | `3` | Consecutive saturated checks before alert |
| `FPM_PROBE_URL` | `http://localhost:8082/` | URL to probe for liveness |
| `FPM_PROBE_TIMEOUT` | `5` | curl timeout in seconds |
| `FPM_WP_CONTAINER` | `pi_wordpress` | WordPress Docker container name |
| `FPM_DB_CONTAINER` | `pi_mariadb` | MariaDB Docker container name |
| `FPM_ALERT_COOLDOWN` | `1800` | Seconds between repeat saturation alerts (30 min) |
| `FPM_AUTO_RESTART` | `false` | Set `true` to auto-restart on saturation |
| `FPM_RESTART_COOLDOWN` | `1200` | Seconds between auto-restarts (20 min) |
| `FPM_CALLBACK_URL` | — | CloudScale Devtools plugin admin-ajax.php URL |
| `FPM_CALLBACK_TOKEN` | — | Token from Debug AI tab in plugin |

### Plugin integration

The **CloudScale Cyber and Devtools** plugin (Debug AI tab → PHP-FPM Saturation Monitor) shows:
- Configurable settings (threshold, cooldown, probe URL, containers)
- A pre-filled `config.env` snippet with a one-click copy button
- Last saturation event timestamp and reason (requires `FPM_CALLBACK_URL` / `FPM_CALLBACK_TOKEN`)
- Restart events reported separately (`type=restarted`) when `FPM_AUTO_RESTART=true`

---

## Daily heartbeat

An optional daily "I'm alive" push notification via ntfy. If the notification stops arriving, the Pi is down or unreachable.

Enable in `config.env`:
```bash
NTFY_HEARTBEAT_ENABLED=true
NTFY_HEARTBEAT_SCHEDULE="0 8 * * *"   # 8:00am daily
```

Then install (or re-run install):
```bash
bash ~/pi2s3/install.sh
```

Each heartbeat includes: uptime, RAM usage, disk usage, Docker container count.

---

## Upgrade

Pull the latest code and redeploy:

```bash
bash ~/pi2s3/install.sh --upgrade
```

This:
- Runs `git pull` in the repo directory
- Redeploys the watchdog binary to `/usr/local/bin/pi2s3-watchdog.sh` (if installed)
- Refreshes the backup cron schedule in case `CRON_SCHEDULE` changed

The `--status` command also detects if the watchdog binary is stale (source updated but binary not redeployed):
```bash
bash ~/pi2s3/install.sh --status
```

---

## Complement with app-layer backups

pi2s3 captures the full machine state but is large (~3–5 GB/image). For cheap, fast, granular data recovery (restore just the database, single-file recovery, cross-version migrations), run an app-layer backup alongside:

| | pi2s3 | App-layer backup |
|---|---|---|
| What's backed up | Entire disk | DB + uploads + config files |
| Compressed size | ~3–5 GB | ~500 MB |
| Restore scenario | Pi hardware failure, OS corruption | DB corruption, accidental delete |
| Restore process | Flash + boot | docker restore commands |
| Knowledge needed | None | Some |
| Cost (60 days) | ~$3/month | <$1/month |

Both are complementary. pi2s3 for disaster recovery; app-layer for day-to-day data safety.

---

## Troubleshooting

**`Cannot detect boot device`**
The script couldn't identify which device the Pi boots from. Check:
```bash
findmnt -n -o SOURCE /
lsblk
```
Override manually by setting `BOOT_DEV` at the top of `pi-image-backup.sh`.

**`partclone not found`**
Re-run `install.sh` or install manually:
```bash
sudo apt install partclone
```

**`Cannot reach s3://your-bucket/`**
Check credentials and IAM permissions:
```bash
aws s3 ls s3://your-bucket/
aws sts get-caller-identity
# Print the required policy with your bucket name:
bash ~/pi2s3/install.sh --iam-policy
```

**`aws CLI not found`**
Re-run `install.sh` or install manually:
```bash
# Pi (aarch64)
curl -sL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
```

**Backup takes too long**
Install `pigz` for parallel compression (4× faster on Pi 5):
```bash
sudo apt install pigz
```

**Filesystem didn't expand after restore**
```bash
sudo raspi-config --expand-rootfs
sudo reboot
```

**SSH host key conflict after restore**
```bash
ssh-keygen -R raspberrypi.local
ssh-keygen -R <ip-address>
```

---

## Manage status

```bash
bash ~/pi2s3/install.sh --status     # show cron, log tail, dependency versions, stale binary check
bash ~/pi2s3/install.sh --uninstall  # remove all cron jobs and logrotate config
bash ~/pi2s3/install.sh --upgrade    # git pull + redeploy watchdog binary + refresh cron
```

---

## License

MIT
