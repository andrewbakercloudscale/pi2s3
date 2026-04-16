# Pi MI — Pi Machine Image

Block-level nightly backup of a Raspberry Pi to AWS S3. Restore a complete, bootable Pi to new hardware in one command — no manual setup, no secrets to re-enter, no git clones.

Think of it as an AMI for your Pi.

---

## How it works

```
BACKUP (runs on Pi nightly via cron)

  1. Stop Docker containers
     └─ ensures databases flush writes before imaging starts

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

  5. Restart Docker containers  (site back up)

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

### Docker downtime

Containers are stopped for the duration of partition imaging — typically **5–15 minutes** (depending on how much data is used) when scheduled at 2am. Docker is restarted immediately after all partitions are imaged.

This is far better than the old `dd` approach (60–90 minutes on a full NVMe), and gives a fully consistent image: databases like MariaDB/InnoDB have all writes flushed to disk and no new writes occur during the backup. On restore, no recovery step is needed.

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
- AWS credentials with `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`

**For restore (Linux):**
- Linux machine with `sfdisk` (util-linux) and `partclone` installed
- AWS CLI v2 with read access to your bucket
- `python3` (for manifest parsing — standard on all modern Linux distros)
- `pv` optional for a live progress bar: `sudo apt install pv`

> **macOS note**: The restore script requires Linux because `sfdisk` and `partclone` are not available on macOS. The easiest approach: boot the new Pi from a minimal SD card, attach the target NVMe, SSH in, and run `pi-image-restore.sh` from there.

---

## Quick start

### 1. Clone on the Pi

```bash
git clone https://github.com/andrewbakercloudscale/pi-mi.git ~/pi-mi
cd ~/pi-mi
```

### 2. Install

```bash
bash install.sh
```

`install.sh` will:
- Prompt for your S3 bucket, AWS region, and ntfy notification URL
- Write `config.env` (gitignored — never committed)
- Install `partclone`, `pigz`, and AWS CLI v2 if not present
- Verify AWS access to your bucket
- Set up S3 lifecycle policy
- Install the nightly cron job (2:00am by default)
- Run a `--dry-run` to confirm everything works

### 3. First backup

```bash
bash ~/pi-mi/pi-image-backup.sh --force
```

Takes 3–10 minutes depending on how full the device is and your network speed. You'll get an ntfy push notification when done.

---

## Configuration

All settings live in `config.env` (copy from `config.env.example`):

```bash
# Required
S3_BUCKET="your-bucket-name"
S3_REGION="us-east-1"
NTFY_URL="https://ntfy.sh/your-topic"

# Retention (default: 60 images)
MAX_IMAGES=60

# AWS
AWS_PROFILE=""                 # blank = default profile or instance role
S3_STORAGE_CLASS="STANDARD_IA" # ~40% cheaper than STANDARD for backups

# Backup behaviour
STOP_DOCKER=true               # stop Docker briefly for DB consistency (~10s)
DOCKER_STOP_TIMEOUT=30         # seconds to wait for containers to stop
CRON_SCHEDULE="0 2 * * *"     # 2:00am daily

# Split-device (advanced)
BACKUP_EXTRA_DEVICE=""         # image a second device alongside boot (see below)

# Notifications
NTFY_LEVEL="all"               # "all" | "failure"
```

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
pi-image-backup.sh [--force] [--dry-run] [--setup] [--list] [--verify[=DATE]]

  --force           Skip the duplicate-check (run even if today's backup exists)
  --dry-run         Show what would happen without uploading anything
  --setup           Create S3 lifecycle policy (run once after install)
  --list            List all backups in S3 with size and hostname
  --verify          Verify latest S3 backup files exist and are non-zero
  --verify=DATE     Verify specific date (YYYY-MM-DD)
```

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

The manifest records hostname, Pi model, OS, partition layout, sizes, duration, and storage class. The `--verify` flag checks all files listed in the manifest exist and are non-zero in S3.

Old images beyond `MAX_IMAGES` are deleted automatically.

---

## Restore to a new Pi

> **Full step-by-step runbook:** [RECOVERY.md](RECOVERY.md) — the document to open when your Pi is dead and you need to restore from scratch. Covers hardware requirements, bootstrap SD flashing from macOS, restore procedure, and post-boot verification.

### Step 1 — Validate (Mac)

Before touching anything, confirm the S3 image is ready:

```bash
bash ~/pi-mi/test-recovery.sh --pre-flash
```

Checks AWS access, confirms image exists and is non-zero, reads the manifest, estimates flash time, prints the restore command.

### Step 2 — Flash (Linux or Pi)

> **Requires Linux** — `sfdisk` and `partclone` are not available on macOS.
>
> **On macOS**: boot the new Pi from a minimal SD card, attach the target NVMe,
> SSH in, clone the repo, and run from there.

```bash
bash ~/pi-mi/pi-image-restore.sh
```

Interactive prompts let you pick the backup date and target device. Streams directly from S3 — no local download needed.

Or restore a specific date non-interactively:
```bash
bash ~/pi-mi/pi-image-restore.sh --date 2026-04-13 --device /dev/nvme0n1 --yes
```

Install `pv` for a live progress bar:
```bash
sudo apt install pv
```

What happens during restore:
1. Partition table downloaded from S3 and applied to target device with `sfdisk`
2. Each partition streamed from S3 → `gunzip` → `partclone.restore` with inline checksum verification
3. Boot firmware partition restored separately (if it was on a separate device)

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
bash ~/pi-mi/test-recovery.sh --post-boot
```

Checks: `config.env` present and configured, filesystem expansion, NVMe mount, Docker + all containers, Cloudflare tunnel, cron jobs, MariaDB tables, memory, load. PASS/FAIL/WARN per check.

### Full walkthrough

```bash
bash ~/pi-mi/test-recovery.sh --guide
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
- Cron jobs present (pi-mi backup + app-layer backup)
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
  → dump diagnostics to /var/log/pi-mi-watchdog-prediag.log
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
bash ~/pi-mi/install.sh --watchdog
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
bash ~/pi-mi/install.sh --watchdog

# Manual test run
sudo /usr/local/bin/pi-mi-watchdog.sh

# Live log tail
sudo journalctl -t pi-mi-watchdog -f

# View today's watchdog activity
sudo journalctl -t pi-mi-watchdog --since today

# View pre-reboot diagnostics (if a watchdog reboot occurred)
sudo cat /var/log/pi-mi-watchdog-prediag.log
```

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
bash ~/pi-mi/install.sh
```

Each heartbeat includes: uptime, RAM usage, disk usage, Docker container count.

---

## Upgrade

Pull the latest code and redeploy:

```bash
bash ~/pi-mi/install.sh --upgrade
```

This:
- Runs `git pull` in the repo directory
- Redeploys the watchdog binary to `/usr/local/bin/pi-mi-watchdog.sh` (if installed)
- Refreshes the backup cron schedule in case `CRON_SCHEDULE` changed

The `--status` command also detects if the watchdog binary is stale (source updated but binary not redeployed):
```bash
bash ~/pi-mi/install.sh --status
```

---

## Complement with app-layer backups

Pi MI captures the full machine state but is large (~3–5 GB/image). For cheap, fast, granular data recovery (restore just the database, single-file recovery, cross-version migrations), run an app-layer backup alongside:

| | Pi MI | App-layer backup |
|---|---|---|
| What's backed up | Entire disk | DB + uploads + config files |
| Compressed size | ~3–5 GB | ~500 MB |
| Restore scenario | Pi hardware failure, OS corruption | DB corruption, accidental delete |
| Restore process | Flash + boot | docker restore commands |
| Knowledge needed | None | Some |
| Cost (60 days) | ~$3/month | <$1/month |

Both are complementary. Pi MI for disaster recovery; app-layer for day-to-day data safety.

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
bash ~/pi-mi/install.sh --status     # show cron, log tail, dependency versions, stale binary check
bash ~/pi-mi/install.sh --uninstall  # remove all cron jobs and logrotate config
bash ~/pi-mi/install.sh --upgrade    # git pull + redeploy watchdog binary + refresh cron
```

---

## License

MIT
