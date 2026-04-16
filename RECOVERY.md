# Pi MI — Disaster Recovery Runbook

This is the step-by-step guide for a full recovery when your Pi is dead and you need to restore from scratch. Keep a copy somewhere you can access without the Pi (this repo, or a printed copy).

---

## What you need

| Item | Notes |
|------|-------|
| New Raspberry Pi 5 | Any revision |
| New NVMe drive | Same size or larger than original (your original was 1TB) |
| NVMe HAT / adapter | For the new Pi |
| Bootstrap microSD card | Any size ≥ 8GB — temporary, just for the first boot |
| Mac (or Linux machine) | To flash the bootstrap SD |
| AWS credentials | You'll re-enter these on the new Pi |

> **Why two storage items?** Your Pi boots from NVMe (root + data) with the SD holding only the boot firmware (`/boot/firmware`). The NVMe is the real DR target. The bootstrap SD is a throwaway — you flash it once to get Linux running, then the restore overwrites the firmware partition on it with your original `/boot/firmware`.

---

## Step 1 — Verify the backup exists (Mac, 1 min)

```bash
cd ~/Desktop/github/pi2s3
bash pi-image-backup.sh --list
```

Confirm today's (or a recent) backup is listed. If you want to verify the S3 files are intact:

```bash
bash pi-image-backup.sh --verify
```

---

## Step 2 — Flash the bootstrap SD (Mac, ~3 min)

Download Raspberry Pi OS Lite (64-bit) and flash to the bootstrap SD.

```bash
# Find your SD card — it will be a small external disk
diskutil list external

# Download Pi OS Lite (arm64, ~500MB)
curl -L https://downloads.raspberrypi.com/raspios_lite_arm64_latest \
  -o /tmp/pi-os-lite.img.xz
xz -d /tmp/pi-os-lite.img.xz

# Flash — replace diskN with your SD card (e.g. disk5)
diskutil unmountDisk /dev/diskN
sudo dd if=/tmp/pi-os-lite.img of=/dev/rdiskN bs=4m status=progress
```

**Enable SSH before ejecting** (mount the SD boot partition and create an empty `ssh` file):

```bash
# The boot partition mounts automatically as "bootfs"
touch /Volumes/bootfs/ssh
```

Optionally add a `userconf.txt` for password login, or use `ssh-keygen` / `cloud-init` for key-based auth. See [Raspberry Pi headless setup docs](https://www.raspberrypi.com/documentation/computers/configuration.html#setting-up-a-headless-raspberry-pi).

Eject the SD:
```bash
diskutil eject /dev/diskN
```

---

## Step 3 — Boot the new Pi

1. Insert the bootstrap SD into the new Pi
2. Connect the new NVMe via the HAT (leave it empty — restore writes to it)
3. Connect ethernet (recommended over WiFi for a large restore)
4. Power on

Find the IP: check your router's DHCP leases, or use `dns-sd -q raspberrypi.local` on Mac. Default hostname is `raspberrypi`.

```bash
ssh pi@raspberrypi.local
# or: ssh pi@<ip-address>
```

Default password for fresh Pi OS is `raspberry` (change it after recovery).

---

## Step 4 — Set up the new Pi for restore (~5 min)

```bash
# Install restore dependencies
sudo apt update -qq
sudo apt install -y partclone pigz pv

# Install AWS CLI v2
curl -sL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, region (af-south-1), output format (json)

# Clone pi-mi
git clone https://github.com/andrewbakercloudscale/pi-mi.git ~/pi-mi

# Create config.env
cp ~/pi-mi/config.env.example ~/pi-mi/config.env
nano ~/pi-mi/config.env
# Set: S3_BUCKET, S3_REGION, NTFY_URL (minimum required values)
```

---

## Step 5 — Run the restore (~20–30 min)

```bash
bash ~/pi-mi/pi-image-restore.sh
```

The script will:
1. List available backups from S3 — select the most recent
2. List available devices — select the NVMe (e.g. `/dev/nvme0n1`)
3. Show a summary and ask for confirmation
4. Stream each partition directly from S3 → gunzip → partclone (no local temp file)
5. Prompt for the boot firmware partition — enter `/dev/mmcblk0p1` (the bootstrap SD's first partition)

The NVMe restore takes ~20 minutes. Progress is shown per partition.

**Non-interactive (if you know the date and device):**
```bash
bash ~/pi-mi/pi-image-restore.sh \
  --date 2026-04-16 \
  --device /dev/nvme0n1
```

---

## Step 6 — Reboot

```bash
sudo reboot
```

The Pi will now boot from the NVMe using the original `/boot/firmware` that was restored to the SD card in Step 5. Root filesystem auto-expands to fill the NVMe on first boot.

---

## Step 7 — Verify

SSH back in (same IP — the restore preserves SSH host keys, so clear the old key first):

```bash
# On Mac — clear old key to avoid host key mismatch
ssh-keygen -R raspberrypi.local
ssh-keygen -R <ip-address>

ssh pi@<ip-address>
```

Check everything is back:

```bash
docker ps                         # all containers running?
systemctl status cloudflared      # tunnel up?
df -h                             # filesystems show correct sizes?
crontab -l                        # backup cron intact?
sudo journalctl -u cloudflared -n 20  # any tunnel errors?
```

Run the full post-boot check:
```bash
bash ~/pi-mi/test-recovery.sh --post-boot
```

---

## Estimated total time

| Step | Time |
|------|------|
| Verify backup + flash bootstrap SD | ~5 min |
| Boot new Pi + install tools | ~8 min |
| Restore from S3 | ~20 min |
| Reboot + verify | ~3 min |
| **Total** | **~35 minutes** |

---

## Future: NVMe-only setup (recommended)

**Current layout:**
```
SD card  (mmcblk0p1, 512MB vfat)  →  /boot/firmware
NVMe p1  (nvme0n1p1, ~860GB ext4) →  /  (root)
NVMe p2  (nvme0n1p2, ~94GB ext4)  →  /mnt/nvme (data)
```
DR requires: new NVMe + SD card (for boot firmware).

**NVMe-only layout:**
```
NVMe p1  (nvme0n1p1, 512MB vfat)  →  /boot/firmware
NVMe p2  (nvme0n1p2, large ext4)  →  /  (root)
NVMe p3  (nvme0n1p3, ext4)        →  /mnt/nvme (data)
```
DR requires: **new NVMe only**. Restore it, put it in the Pi, done. No SD needed.

**When to migrate:** Do this the next time you restore to new hardware — set up the new NVMe with the NVMe-only layout rather than applying the original partition table. Then configure EEPROM on both Pis to boot NVMe-first:

```bash
# On the Pi — set boot order to try NVMe first
sudo raspi-config
# → Advanced Options → Boot Order → NVMe/USB Boot

# Or directly via rpi-eeprom-config:
sudo -E rpi-eeprom-config --edit
# Set: BOOT_ORDER=0xf416   (NVMe → USB → SD → restart)
```

The existing backup script already handles NVMe-only correctly — if `/boot/firmware` is on the NVMe, it's captured automatically as part of the NVMe partition backup. No script changes needed.

After migrating, the SD card can be removed entirely. Keep one blank SD in a drawer as emergency bootstrap media.

---

## If things go wrong

**"SSH connection refused after reboot"**
The Pi may still be booting. Wait 60 seconds and retry. If still unreachable, check HDMI output for boot errors.

**"Filesystem didn't expand"**
```bash
sudo raspi-config --expand-rootfs && sudo reboot
```

**"Docker containers not starting"**
```bash
docker ps -a          # see stopped containers
docker compose up -d  # restart stack (from compose dir)
```

**"Cloudflare tunnel not connecting"**
```bash
sudo systemctl restart cloudflared
sudo journalctl -u cloudflared -n 50
```

**"Wrong NVMe device selected during restore"**
Re-run the restore with `--force` flag and select the correct device. The previous (partial) restore will be overwritten.

**Restore took longer than expected**
Normal — S3 download speed from `af-south-1` to Cape Town varies. A 17GB compressed restore typically takes 20–35 minutes depending on your ISP.
