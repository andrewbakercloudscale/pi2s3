# pi2s3 Disaster Recovery Quickstart

Restore a full Pi backup from S3 onto a new Pi in under 30 minutes.

## What you need

- Spare Raspberry Pi 5
- NVMe drive (installed in the Pi)
- microSD card (256GB works fine — only used for initial setup, discarded after)
- Mac or Linux machine to flash the SD card
- AWS credentials with read access to your S3 bucket
- Ethernet cable (recommended — WiFi setup can be unreliable on first boot)

---

## Step 1 — Flash Pi OS Lite to SD card

Download Pi OS Lite ARM64:

```bash
curl -L https://downloads.raspberrypi.com/raspios_lite_arm64_latest -o pi-os.img.xz
xz -d pi-os.img.xz
sudo dd if=pi-os.img of=/dev/rdisk<N> bs=4m status=progress && sync
```

Replace `<N>` with your SD card disk number (`diskutil list` to find it).

---

## Step 2 — Write cloud-init files to boot partition

```bash
cp extras/cloud-init/user-data   /Volumes/bootfs/user-data
cp extras/cloud-init/network-config /Volumes/bootfs/network-config
cp extras/cloud-init/meta-data   /Volumes/bootfs/meta-data
touch /Volumes/bootfs/ssh
```

**Edit before booting:**

- `network-config` — set your WiFi SSID and password (or leave as-is if using ethernet)
- `meta-data` — set a unique `instance_id` (e.g. `pi2s3-dr-YYYYMMDD`) — **critical**: cloud-init skips runcmd if it sees the same instance_id from a previous flash
- `user-data` — set `hostname`, `passwd` hash, and `config.env` values to match your setup

Eject the card:
```bash
diskutil eject /dev/disk<N>
```

---

## Step 3 — Boot the Pi

1. Insert NVMe into the Pi (do this before booting)
2. Insert SD card
3. Power on

**Ethernet is strongly recommended** — plug a cable in before powering on. WiFi on Pi 5 / Pi OS Bookworm requires the regulatory domain to be set correctly; ethernet works immediately.

SSH becomes available within ~1 minute (before package installs complete).

---

## Step 4 — SSH in and verify

```bash
ssh pi@andrewninja-pi-qa.local
# or by IP if mDNS isn't working yet:
# ssh pi@<ip-from-router-dhcp-list>
```

Default password: `pi2s3-dr` (change this in user-data before production use).

Check NVMe is visible:
```bash
lsblk | grep nvme
# Should show: nvme0n1  ...  disk
```

---

## Step 5 — Set up AWS credentials

```bash
aws configure --profile personal
# Enter: Access Key ID, Secret Access Key, region (af-south-1), output (json)
```

Verify access:
```bash
aws s3 ls s3://your-s3-bucket-name/pi-image-backup/ --profile personal
```

---

## Step 6 — Run the restore

```bash
sudo bash ~/pi2s3/pi-image-restore.sh \
  --device /dev/nvme0n1 \
  --host andrew-pi-5 \
  --date 2026-04-23 \
  --resize \
  --yes
```

- `--host` — the hostname whose backups to restore (matches S3 prefix under `pi-image-backup/`)
- `--date` — omit to restore the latest backup
- `--resize` — expands the last partition to fill the NVMe (required when restoring to a larger drive)

This streams directly from S3 — no local disk space needed. Takes ~20–30 min for a 7–8 GB compressed backup on a 100Mbps link.

---

## Step 7 — Boot from NVMe

Once restore completes:

1. Power off the Pi
2. Remove the SD card
3. Power on — Pi boots from NVMe

---

## Step 8 — Set up Cloudflare tunnel

Install cloudflared and create a new tunnel for `qa.andrewbaker.ninja`:

```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
cloudflared tunnel login
cloudflared tunnel create andrewninja-pi-qa
# Edit ~/.cloudflared/config.yml with tunnel ID and qa.andrewbaker.ninja ingress
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Then add a CNAME in Cloudflare DNS: `qa.andrewbaker.ninja` → `<tunnel-id>.cfargotunnel.com`.

---

## Common pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| SSH not up after 10+ min | `packages:` block in user-data delays ssh module | Use `runcmd` for packages (see template) |
| cloud-init skips runcmd | Same `instance_id` as previous flash | Change `instance_id` in meta-data before each flash |
| `No backups found` error | Script running as sudo, AWS looks in `/root/.aws/` | Fixed in pi-image-restore.sh v2+ via `SUDO_USER` detection |
| WiFi `wlan0: unavailable` | No regulatory domain set on Pi 5 | `iw reg set ZA` + `renderer: NetworkManager` in network-config |
| Wrong host's backups | New Pi hostname doesn't match S3 prefix | Use `--host <original-hostname>` flag |
