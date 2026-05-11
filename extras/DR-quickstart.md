# pi2s3 Disaster Recovery Quickstart

Restore a full Pi backup from S3 onto new hardware in under 30 minutes.
Works on **WiFi only** — no ethernet required.

---

## What you need

- Spare Raspberry Pi 5 with NVMe drive installed
- microSD card (any size — 8 GB+ works)
- Mac to prepare the SD card
- Cloudflare tunnel for the new Pi (create one if you haven't — see Step 1)
- AWS credentials with read access to your S3 bucket

---

## Step 1 — Create a Cloudflare tunnel for the new Pi

Run on your Mac. Skip if you already have a tunnel.

```bash
cloudflared tunnel create andrewninja-pi-qa
# Note the tunnel UUID printed — you'll need it in Step 2

# Add a DNS record in Cloudflare pointing at the tunnel:
#   CNAME: qa.andrewbaker.ninja → <TUNNEL_UUID>.cfargotunnel.com
```

---

## Step 2 — Flash + prepare the SD card

**Option A — Let prepare-sd.sh do everything (recommended):**

```bash
bash extras/firstboot/prepare-sd.sh --flash --cf-api-token <CF_API_TOKEN>
```

This downloads Pi OS Lite ARM64, flashes it, and configures WiFi + cloudflared in one go.
Answer the prompts: SD disk, WiFi SSID/password, Pi password, tunnel UUID, CF hostname.

> **`--cf-api-token` is strongly recommended.** cloudflared fetches its ingress rules
> from Cloudflare's API at startup and ignores the local `config.yml` ingress section
> when a remote config already exists on the tunnel. Without this flag the catch-all
> stays as `http_status:404`, which means any hostname that isn't explicitly listed
> (e.g. `andrewbaker.ninja` during a DNS-swap failover) will return 404.
> The token needs **Cloudflare Tunnel: Edit** permission for your account.

**Option B — Flash with Raspberry Pi Imager first, then inject:**

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choose **Raspberry Pi OS Lite (64-bit)**
3. In OS Customisation: set hostname, username/password, WiFi, enable SSH
4. Flash the card
5. Run:

```bash
bash extras/firstboot/prepare-sd.sh --cf-api-token <CF_API_TOKEN>
```

This adds cloudflared to the card Pi Imager already prepared.

---

## Step 3 — Boot the Pi

1. Insert NVMe into the Pi (do this before powering on)
2. Insert the SD card
3. Power on

The Pi will:
- Connect to WiFi on first boot
- Install cloudflared from the SD card (no internet download)
- Start the Cloudflare tunnel

**Wait ~3 minutes**, then check the tunnel is healthy:

```bash
cloudflared tunnel info <TUNNEL_UUID>
# or: cloudflared tunnel list
```

---

## Step 4 — SSH in via Cloudflare

Add to `~/.ssh/config` (one-time):

```
Host qa.andrewbaker.ninja
    ProxyCommand cloudflared access ssh --hostname %h
    User admin
```

Then:

```bash
ssh qa.andrewbaker.ninja
```

If `qa.andrewbaker.ninja` has a Cloudflare Access policy, your browser will open for auth on first use.

Check that the NVMe is visible:

```bash
lsblk | grep nvme
# Should show: nvme0n1  ...  disk
```

---

## Step 5 — Set up AWS credentials

```bash
aws configure
# Enter: Access Key ID, Secret, region (af-south-1), output (json)

# Verify:
aws s3 ls s3://your-bucket/pi-image-backup/
```

---

## Step 6 — Run the restore

```bash
curl -sL pi2s3.com/restore | bash
```

Or run directly:

```bash
sudo bash ~/pi2s3/pi-image-restore.sh \
  --device /dev/nvme0n1 \
  --host andrew-pi-5 \
  --resize \
  --yes
```

This streams the backup directly from S3. Takes ~20-30 min for a 7-8 GB backup.

---

## Step 7 — Wire up NVMe boot

After restore, run the boot-wiring script while still on the SD:

```bash
sudo bash ~/pi2s3/extras/post-restore-nvme-boot.sh
```

This:
- Fixes `/etc/fstab` PARTUUIDs for the new SD card
- Points `cmdline.txt` `root=` at the NVMe partition
- Adds `rootdelay=5` for NVMe PCIe enumeration

---

## Step 8 — Swap cloudflared to the QA tunnel

The restored NVMe contains the **production** cloudflared config. Before rebooting, swap it:

```bash
# Find where the NVMe root is mounted (from post-restore output)
RESTORE_ROOT=$(mount | awk '/nvme0n1p2/{print $3; exit}')

sudo sed -i "s/tunnel: .*/tunnel: <QA_TUNNEL_UUID>/"          "${RESTORE_ROOT}/etc/cloudflared/config.yml"
sudo sed -i "s|credentials-file:.*|credentials-file: /root/.cloudflared/<QA_TUNNEL_UUID>.json|" \
                                                               "${RESTORE_ROOT}/etc/cloudflared/config.yml"
sudo cp /root/.cloudflared/<QA_TUNNEL_UUID>.json               "${RESTORE_ROOT}/root/.cloudflared/"
```

Then sync the **remote** tunnel config so cloudflared serves any hostname via WordPress
(cloudflared ignores the local `ingress:` section when a remote config exists):

```bash
CF_ACCOUNT_ID="<your-account-id>"
CF_API_TOKEN="<CF_API_TOKEN>"   # Tunnel:Edit permission
QA_TUNNEL_UUID="<QA_TUNNEL_UUID>"
CF_HOSTNAME="<your-ssh-hostname>"   # e.g. ssh-qa.andrewbaker.ninja

curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${QA_TUNNEL_UUID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"config\":{\"ingress\":[{\"hostname\":\"${CF_HOSTNAME}\",\"service\":\"ssh://localhost:22\"},{\"service\":\"http://127.0.0.1:8082\"}]}}"
```

---

## Step 9 — Reboot into NVMe

```bash
sudo reboot
```

The Pi will boot from NVMe, connect to WiFi, and come up on the QA CF tunnel.
SSH back in the same way: `ssh qa.andrewbaker.ninja`

---

## Step 10 — Pair as a hot standby

A cloned Pi becomes a live standby once you pair its Cloudflare tunnel with your
main domain and wire up automatic DNS failover. When prod goes down, DNS swaps to
the standby in under two minutes; when prod recovers, it swaps back.

```
Prod Pi    ── CF tunnel: <PROD_UUID> ──┐
                                        ├── CNAME yourdomain.com  (swaps on failover)
Standby Pi ── CF tunnel: <QA_UUID>   ──┘

CF Worker watches prod heartbeats and updates the CNAME automatically.
```

### 10a — Verify both remote tunnel configs serve HTTP (not 404)

cloudflared ignores the local `config.yml` ingress when a remote config exists on
Cloudflare's side. Check both tunnels — the catch-all must forward to your app,
not return `http_status:404`:

```bash
CF_ACCOUNT_ID="<your-account-id>"
CF_API_TOKEN="<your-token>"   # Tunnel:Edit permission

for UUID in <PROD_UUID> <QA_UUID>; do
  echo "=== ${UUID} ==="
  curl -s "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${UUID}/configurations" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
for r in cfg['result']['config']['ingress']:
    print(r.get('hostname','*'), '->', r['service'])
"
done
# Catch-all line should be:  * -> http://127.0.0.1:<port>
# NOT:                        * -> http_status:404
```

Fix a wrong catch-all (run once per tunnel that needs it):

```bash
UUID="<the-tunnel-uuid>"
SSH_HOSTNAME="ssh-standby.yourdomain.com"  # or ssh.yourdomain.com for prod
APP_PORT=8082

curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${UUID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"config\":{\"ingress\":[
        {\"hostname\":\"${SSH_HOSTNAME}\",\"service\":\"ssh://localhost:22\"},
        {\"service\":\"http://127.0.0.1:${APP_PORT}\"}
      ]}}"
```

> Running `prepare-sd.sh --cf-api-token` sets this correctly at SD-card prep time.

### 10b — DNS records

Three CNAMEs in Cloudflare DNS (all proxied):

| Name | Points to | Swaps on failover? |
|------|-----------|-------------------|
| `yourdomain.com` | `<PROD_UUID>.cfargotunnel.com` | Yes → QA UUID |
| `www.yourdomain.com` | `<PROD_UUID>.cfargotunnel.com` | Yes → QA UUID |
| `ssh-standby.yourdomain.com` | `<QA_UUID>.cfargotunnel.com` | No — fixed |

`ssh-standby.yourdomain.com` is permanent. The failover mechanism only touches
the main domain and www.

### 10c — SSH access to the standby without browser auth

```bash
# 1. Cloudflare dashboard → Access → Service Auth → Create Service Token
#    Assign it to the SSH Access application for ssh-standby.yourdomain.com
#    Note the Client ID and Secret.

# 2. Make sure your SSH public key is in authorized_keys on the standby:
ssh-copy-id -i ~/.ssh/your_pi_key.pub <user>@ssh-standby.yourdomain.com
```

Add to `~/.ssh/config`:

```
Host ssh-standby.yourdomain.com
    ProxyCommand cloudflared access ssh --hostname ssh-standby.yourdomain.com \
                 --id <CF-Access-Client-Id> \
                 --secret <CF-Access-Client-Secret>
    User <pi-username>
    IdentityFile ~/.ssh/your_pi_key
    StrictHostKeyChecking no
```

### 10d — Heartbeat + DNS-swap worker

Deploy a Cloudflare Worker + KV namespace that:

1. Accepts `POST /heartbeat` from prod Pi every minute
2. On a 60-second schedule: if last heartbeat is > 2 min old → outage
3. **On outage**: update `yourdomain.com` + `www` CNAMEs to `<QA_UUID>.cfargotunnel.com`, send alert
4. **On recovery**: swap CNAMEs back to `<PROD_UUID>.cfargotunnel.com`, send recovery alert

Add to prod Pi crontab (`crontab -e`):

```bash
* * * * * curl -s -X POST "https://uptime.yourdomain.com/heartbeat" \
  -H "Authorization: Bearer <heartbeat-token>" >/dev/null 2>&1
```

### 10e — Run a failover drill

```bash
# Enable test mode — treats all incoming heartbeats as failures
curl -s -X POST "https://uptime.yourdomain.com/admin/test-mode" \
  -H "Authorization: Bearer <admin-token>" \
  -d '{"enabled":true}'

# Wait ~2 minutes. You should receive an outage alert and DNS swaps to standby.

# Verify standby is serving:
curl -I https://yourdomain.com   # expect 200 from standby Pi

# Disable test mode — prod recovers, DNS swaps back automatically
curl -s -X POST "https://uptime.yourdomain.com/admin/test-mode" \
  -H "Authorization: Bearer <admin-token>" \
  -d '{"enabled":false}'

# Force immediate swap back to prod without waiting for the next heartbeat cycle:
curl -s -X POST "https://uptime.yourdomain.com/admin/force-prod" \
  -H "Authorization: Bearer <admin-token>"
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Tunnel never shows healthy | `cat /boot/firmware/pi2s3-firstboot.log` — check dpkg/systemctl errors |
| `firstrun.sh` didn't run | Check `cmdline.txt` has `systemd.run=` or re-run `prepare-sd.sh` |
| Pi won't boot from NVMe | `bash extras/recover-sd-boot.sh` (from Mac with SD card inserted) |
| AWS access denied | `aws sts get-caller-identity` — re-run `aws configure` |
| `No backups found` | Script running as sudo — fixed in v2+. Use `--host <hostname>` flag |
| NVMe not found (`lsblk`) | NVMe not seated. Check PCIe connection and reboot |
| Site returns 404 after failover | Remote tunnel config still has `http_status:404`. Run the `curl -X PUT .../configurations` command in Step 8, or re-run `prepare-sd.sh --cf-api-token` |

**Check the firstboot log first for any tunnel issue:**
```bash
cat /boot/firmware/pi2s3-firstboot.log
```

**Run the full diagnostic if the restore behaves unexpectedly:**
```bash
sudo bash ~/pi2s3/extras/diagnose-restore.sh
```
