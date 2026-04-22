# pi2s3 extras

Optional add-ons for specific setups. The core backup and restore scripts work without any of these.

## cf-tunnel-watchdog.sh

Self-healing monitor for Pis that serve public traffic via a Cloudflare tunnel. Runs every 5 minutes as root, checks HTTP + tunnel health, and auto-recovers through three escalating phases before rebooting.

**Who needs this:** only if you're running a Cloudflare tunnel (`cloudflared`) on your Pi.

**Install:**
```bash
# 1. Add the CF and watchdog settings from extras/config.env.example to your config.env
# 2. Set CF_WATCHDOG_ENABLED=true in config.env
# 3. Run:
bash ~/pi2s3/install.sh --watchdog
```

## fpm-saturation-monitor.sh

PHP-FPM worker pool saturation monitor for WordPress setups. Detects exhaustion via HTTP probe and MariaDB query inspection. Alerts via ntfy, auto-restarts the WordPress container if `FPM_AUTO_RESTART=true`. Also kills orphaned `pi2s3-lock` connections left by crashed backups.

**Who needs this:** only if you're running WordPress with PHP-FPM on your Pi.

**Install:**
```bash
# 1. Add the FPM settings from extras/config.env.example to your config.env
# 2. Add to crontab:
crontab -e
# Add: * * * * * bash ~/pi2s3/extras/fpm-saturation-monitor.sh 2>/dev/null
```

## post-restore-example.sh

Template for `--post-restore` hooks. When passed to `pi-image-restore.sh`, this script runs inside the restored filesystem before reboot — useful for cloning a Pi to a second site with a different Cloudflare tunnel, hostname, or `.env` values.

**Who needs this:** anyone cloning a Pi to a staging, office, or dev environment.

**Usage:**
```bash
# Copy and customise for your target environment
cp ~/pi2s3/extras/post-restore-example.sh ~/post-restore-office.sh
nano ~/post-restore-office.sh   # set NEW_HOSTNAME, CF tunnel credentials, .env changes

# Pass it to the restore:
bash ~/pi2s3/pi-image-restore.sh \
  --date latest --device /dev/nvme0n1 \
  --post-restore ~/post-restore-office.sh
```

The restored root is mounted read-write at `$RESTORE_ROOT`. Any changes made to `$RESTORE_ROOT/...` persist to the target device.

## build-recovery-usb.sh + recovery-launcher.sh

Build a bootable Raspberry Pi OS Lite image with pi2s3 pre-installed. Flash to a USB stick or SD card and keep it in a drawer. Plug into any Pi 5, power on — it auto-logs in and launches the restore wizard without any laptop, SD card, or internet access needed.

**Who needs this:** anyone who wants a zero-prerequisite disaster recovery drive, or wants to hand a ready-to-go restore stick to a remote site.

**Build the image** (requires Linux, ~6 GB free, ~15 min):
```bash
# On x86_64: install QEMU first
sudo apt install qemu-user-static binfmt-support

bash ~/pi2s3/extras/build-recovery-usb.sh
# → pi2s3-recovery-usb-YYYY-MM-DD.img.xz
```

**Or download a pre-built image** from [GitHub Releases](https://github.com/andrewbakercloudscale/pi2s3/releases).

**Flash and use:**
```bash
# Flash with Raspberry Pi Imager (choose "Use custom"), or:
xz -d pi2s3-recovery-usb-*.img.xz
sudo dd if=pi2s3-recovery-usb-*.img of=/dev/sdX bs=4M status=progress
```
Boot, enter your S3 bucket + AWS credentials when prompted. Default SSH password: `recovery`.

## config.env.example

Full config for both extras. Copy the relevant section into your `~/pi2s3/config.env`.
