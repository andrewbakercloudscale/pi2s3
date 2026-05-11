# pi2s3 — TODO

All four planned items are complete as of v1.7.0.

---

## 5. Fix and validate DR-quickstart.md WiFi setup path — DONE

Replaced cloud-init approach (unreliable over WiFi on Pi OS Bookworm) with
`extras/firstboot/prepare-sd.sh` — a Mac-side script that prepares the SD card
after Raspberry Pi Imager (or does the full download+flash itself with `--flash`).

What was built:
- `extras/firstboot/prepare-sd.sh` — inject or full-flash mode; caches cloudflared
  .deb locally, injects into Pi Imager's firstrun.sh or writes from scratch
- `extras/DR-quickstart.md` — full rewrite using firstboot approach, WiFi-only path
- `website/restore` — added network check + guidance for WiFi-only bootstrapping

SSH via CF Access (`qa.andrewbaker.ninja`):
```
Host qa.andrewbaker.ninja
    ProxyCommand cloudflared access ssh --hostname %h
    User admin
```

---

## 1. Clone / staging environments — DONE (v1.7.0)

`--post-restore <script>` flag on `pi-image-restore.sh`. Mounts the restored root partition, exports `RESTORE_ROOT`, and runs the user script before first boot. Template at `extras/post-restore-example.sh`.

```bash
bash pi-image-restore.sh --date latest --device /dev/nvme0n1 --post-restore ~/post-restore-office.sh
```

---

## 2. Pre-made recovery / clone USB — DONE (v1.7.0)

`extras/build-recovery-usb.sh` builds a bootable Pi OS Lite ARM64 image with all tools pre-installed. GitHub Actions workflow publishes it as a GitHub Release. On first boot: auto-login → credential prompt → restore wizard.

Pre-built images: [GitHub Releases](https://github.com/andrewbakercloudscale/pi2s3/releases) (tagged `recovery-usb/YYYY-MM-DD`).

---

## 3. HTTP netboot from AWS (Pi 5) — DONE (v1.7.0)

`extras/setup-netboot.sh` configures Pi 5 EEPROM. `extras/build-netboot-image.sh` builds kernel + initramfs. Boot files served from `boot.pi2s3.com` (CloudFront → S3). Terraform in `extras/terraform/boot-infrastructure/`.

**Still needed before this works end-to-end:**
- Apply Terraform to stand up `boot.pi2s3.com`
- Trigger the Build Netboot Image GitHub Actions workflow to publish boot files

---

## 4. Fleet deployment (school / many Pis) — DONE (v1.7.0)

`extras/fleet-deploy.sh` reads a CSV manifest, SSHes into each recovery-mode Pi, copies `config.env` + per-Pi post-restore script, runs restore non-interactively. Supports `--parallel`, `--dry-run`, `--only <name>`.

Example manifest + classroom post-restore template in `extras/fleet-example/`.

```bash
bash extras/fleet-deploy.sh fleet.csv --parallel
```

---

## Next ideas (not yet scoped)

- Embed AWS credentials in Pi 5 EEPROM `CUSTOM_ETH_CONFIG` for fully unattended netboot restore
- GitHub Actions auto-rebuild of netboot/USB images when pi2s3 code changes
- `--verify` flag on fleet-deploy to confirm all Pis came back up cleanly after restore
