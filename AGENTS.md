# AGENTS.md — running pi2s3 as an AI agent

This file tells an AI coding agent (Claude Code, etc.) how to **back up a machine
with pi2s3** end-to-end, unattended. If a user says *"backup my site with
pi2s3"*, follow this.

pi2s3 takes a block-level image of a Linux machine's disk (a Raspberry Pi by
design, but any 64-bit Linux host) and streams it to AWS S3. It is two bash
scripts — `pi-image-backup.sh` and `pi-image-restore.sh` — plus `install.sh`.
There are no daemons and nothing to build.

## Ground rules

1. **Run on the host you're backing up.** The backup images local block devices,
   so the commands must run *on the machine being backed up* (e.g. the Pi),
   either directly or over SSH. If you're not on it, SSH in first.
2. **Linux + root.** Imaging needs `sudo`/root and Linux-only tools (`partclone`,
   `sfdisk`). It will not run on macOS.
3. **Never invent AWS credentials or a bucket name.** If they aren't already
   configured, ask the user. Do not guess.
4. **Confirm before the first upload** if the user hasn't already said "just do
   it". A backup uploads several GB to S3 and costs money.
5. This is backup software — it is **safe and non-destructive** on the source
   host. (`pi-image-restore.sh` *writes* to a target device and is destructive —
   never run restore unless explicitly asked.)

## Decision flow

### Step 0 — Are we on the right machine?
```bash
uname -s   # must be Linux
test -b /dev/nvme0n1 || test -b /dev/mmcblk0 || lsblk   # confirm local disk
```
If not Linux, tell the user to run you (or SSH) on the host being backed up.

### Step 1 — Is pi2s3 already installed and configured?
```bash
test -f ~/pi2s3/pi-image-backup.sh && test -f ~/pi2s3/config.env && echo INSTALLED
```
- **INSTALLED** → skip to Step 4 (just run the backup).
- Not installed → Step 2.

### Step 2 — Gather what install needs
pi2s3 needs an **S3 bucket name**, an **AWS region**, and **working AWS
credentials**. Check credentials:
```bash
aws sts get-caller-identity   # must succeed
```
If that fails, AWS isn't set up — ask the user to provide credentials (an IAM
user with the policy in `iam-policy.json`, an instance role, or `aws configure`).
Ask the user for the **bucket name** and **region** if you don't already know
them. (The IAM policy can be printed later with
`bash ~/pi2s3/install.sh --iam-policy`.)

### Step 3 — Install non-interactively
The installer supports a fully unattended mode via env vars — use it:
```bash
git clone https://github.com/andrewbakercloudscale/pi2s3.git ~/pi2s3
cd ~/pi2s3
S3_BUCKET="<bucket>" S3_REGION="<region>" NTFY_URL="" PI2S3_YES=1 bash install.sh
```
- `PI2S3_YES=1` auto-confirms prompts (it will create the bucket if missing and
  run a first backup).
- Set `NTFY_URL="https://ntfy.sh/<your-topic>"` to get a push notification when
  the backup finishes; leave empty for none.
- If `install.sh` errors that AWS creds are missing, stop and resolve Step 2 —
  do **not** loop.

### Step 4 — Run the backup
```bash
bash ~/pi2s3/pi-image-backup.sh --force
```
- `--force` runs even if today's backup already exists.
- Add `--dry-run` first if you want to show the plan without uploading.
- Takes ~3–10 min depending on used disk and upload speed.

### Step 5 — Confirm it landed
```bash
bash ~/pi2s3/pi-image-backup.sh --verify
bash ~/pi2s3/pi-image-backup.sh --list
```
Report the result to the user: backup date, compressed size, and verify status.

## Databases (handled automatically — no action needed)

pi2s3 quiesces a running database for a consistent image with **zero downtime**,
auto-detecting it whether it runs in Docker or natively on the host:

- **MariaDB / MySQL** → `SET GLOBAL read_only=ON` for the sub-10-second flush
  window, then restored. A replica that is already read-only is left untouched.
  A **native** install needs `DB_ROOT_PASSWORD` set in `config.env` (there's no
  container env to read it from).
- **PostgreSQL** → a `CHECKPOINT`; writes are never blocked. Set `DB_PG_USER`
  if the superuser isn't `postgres`.
- **No DB detected** → Docker (or services named in `PRE_BACKUP_CMD`) are stopped
  briefly during imaging.

You normally don't touch any of this. Only edit `config.env` (`DB_ENGINE`,
`DB_ROOT_PASSWORD`, `DB_PG_USER`) if the user reports the DB wasn't detected.

## Scheduling

`install.sh` installs a nightly cron job (2am by default). To change it, set
`CRON_SCHEDULE` in `config.env` and re-run `bash ~/pi2s3/install.sh --upgrade`.

## Don't

- Don't run `pi-image-restore.sh` unless explicitly asked — it overwrites a disk.
- Don't disable any security tooling on the host to "make it work".
- Don't hardcode secrets into `config.env` in a way that gets committed —
  `config.env` is gitignored; keep it that way.

## More

Full docs: `README.md` in this repo, or <https://pi2s3.com>. Machine-readable
summary for agents: <https://pi2s3.com/llms.txt>.
