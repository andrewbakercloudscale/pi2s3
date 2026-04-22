# pi2s3 — TODO

---

## 1. Clone / staging environments

**Use case:** Restore a pi2s3 image to a second Pi (office, staging, dev) and have it come up as a different site — different Cloudflare tunnel, different subdomain, different hostname — without manual editing after restore.

**What's needed:**
- `--post-restore <script>` flag on `pi-image-restore.sh`
- Script runs inside the restored filesystem before reboot (chroot or post-boot via rc.local hook)
- User provides a `post-restore-office.sh` that swaps CF tunnel credential, updates hostname, updates `.env` vars
- Could ship example templates: `extras/post-restore-example.sh`

**Outcome:** `bash pi-image-restore.sh --date latest --device /dev/nvme0n1 --post-restore ~/post-restore-office.sh` → running copy of the site in one command.

---

## 2. Pre-made recovery / clone USB

**Use case:** Keep a bootable USB drive in a drawer (or post one to a remote site). Plug into any Pi 5, power on — it boots directly into a pi2s3 restore environment with no SD card, no laptop, no Raspberry Pi Imager needed.

**What's needed:**
- Build a minimal Raspberry Pi OS Lite image (~1 GB) with pre-installed: `partclone`, `pigz`, `pv`, `aws-cli`, `pi2s3` repo
- On first boot: auto-run `curl -sL pi2s3.com/restore | bash` (or just exec the local copy)
- Publish as a downloadable `.img.xz` from GitHub Releases / S3
- Users flash it once with Raspberry Pi Imager and keep it on a shelf

**Outcome:** DR or clone with zero prerequisites on the recovery machine.

---

## 3. HTTP netboot from AWS (Pi 5)

**Use case:** Boot a Pi 5 into a pi2s3 restore/clone environment with no physical media at all — just power + ethernet. Works for single Pi (office) and fleets (school).

**How Pi 5 HTTP boot works:**
- Pi 5 EEPROM supports `BOOT_ORDER` entry `7` = HTTP boot
- Pi gets an IP via DHCP from the local router (standard, nothing to configure)
- Pi fetches kernel + initramfs from a configurable HTTP URL — can be anywhere on the internet
- We host boot files on S3 / CloudFront at `boot.pi2s3.com`

**What's needed:**
- Build a pi2s3 rescue initramfs: minimal Linux + partclone + pigz + aws-cli + restore script
- Host boot files (kernel, initrd, config.txt, cmdline.txt) on S3/CloudFront at `boot.pi2s3.com`
- EEPROM configuration script: `bash pi2s3/extras/setup-netboot.sh` — sets `HTTP_HOST=boot.pi2s3.com` in EEPROM config and reboots
- On netboot: initramfs prompts for AWS credentials, lists S3 backups, restores to target device
- Optional: embed AWS credentials / S3 bucket in EEPROM `CUSTOM_ETH_CONFIG` so restore is fully unattended

**Infrastructure:**
- S3 bucket `boot.pi2s3.com` (or subfolder of existing bucket) — serves static boot files
- CloudFront distribution in front for low-latency global delivery
- Boot files updated via CI when initramfs changes

**Outcome:** Configure EEPROM once (`bash extras/setup-netboot.sh`). Next time Pi boots with no NVMe attached (or NVMe blank), it automatically fetches restore environment from AWS and starts the restore flow.

---

## 4. Fleet deployment (school / many Pis)

**Use case:** Deploy an identical pi2s3 image to 10–100 Pis on the same network. Each Pi gets the same base OS + apps, then diverges with per-Pi config (hostname, credentials).

**Builds on:** HTTP netboot (#3) + post-restore hook (#1)

**What's needed:**
- HTTP netboot configured on all fleet Pis (one-time EEPROM setup, can be scripted)
- A fleet manifest: maps hostname → S3 backup date + post-restore script
- `extras/fleet-deploy.sh` — iterates the manifest, SSH into each Pi (or trigger via netboot), restores + customises
- Per-Pi post-restore scripts handle: hostname, SSH keys, app credentials, CF tunnel

**Outcome:** `bash extras/fleet-deploy.sh fleet.csv` → N Pis imaged and customised from one command on a management machine.

---

## Priority order

| # | Feature | Effort | Value |
|---|---------|--------|-------|
| 1 | Post-restore hook (`--post-restore`) | Low | High — unlocks clone/staging today |
| 2 | Pre-made recovery USB image | Medium | High — zero-prereq DR + easy handoff |
| 3 | HTTP netboot from AWS | High | High — no physical media, fleet-ready |
| 4 | Fleet deployment tooling | Medium (builds on 3) | High for multi-Pi |
