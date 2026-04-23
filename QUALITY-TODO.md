# pi2s3 — Code Quality TODO

Generated from bash repository analysis (2026-04-23). 21 findings across 10 scripts.

---

## 🔴 Critical

- [x] **[C1]** `pi-image-restore.sh:917` — `break` inside a function's `case` — should be `return 1`. `break` with no enclosing loop skips the filesystem abort, letting `resize2fs` run on a corrupt partition.

---

## 🟠 High

- [x] **[H1]** `install.sh:111` — Spurious `cat |` before `sudo tee <<'HEREDOC'`. The heredoc overrides the pipe for tee's stdin; `cat` inherits the terminal and reads until SIGPIPE. Remove the `cat |`.
- [x] **[H2]** `install.sh:525–532` — `aws s3 mb ... && ok ... || die` — `die` fires if `ok()` returns non-zero even when the bucket was created. Rewrite as `if/else`.
- [x] **[H3]** `test-recovery.sh:221–224` — `[[ -n ... ]] && pass ... || { fail; exit 1 }` — exits with a false failure if `pass()` returns non-zero. Rewrite as `if/else`. (Same pattern at lines 393–397.)
- [x] **[H4]** `install.sh:473, 547, 563–565, 714` — `cmd && ok ... || warn` — `warn` fires after a successful operation if `ok()` returns non-zero. Rewrite as `if/else`. (4 occurrences.)

---

## 🟡 Medium

- [ ] **[M1]** `pi-image-backup.sh:86,102,103` / `pi-image-restore.sh:58,71,72` / `extras/fleet-deploy.sh:90,91,122` — Startup `echo "ERROR: ..."` lines go to stdout; add `>&2`.
- [ ] **[M2]** `pi-image-restore.sh:85` — `VERIFY_DATE_FOR_VERIFY=""` declared but never read. Remove it.
- [ ] **[M3]** `extras/build-recovery-usb.sh:33` / `extras/build-netboot-image.sh:30` — `REPO_DIR` computed but never used. Remove both lines.
- [ ] **[M4]** `deploy-pi.sh:12–13` — `PI_KEY` and `PI_LOCAL` hardcoded to machine-specific paths. Document or parameterise.
- [ ] **[M5]** `extras/cf-tunnel-watchdog.sh:1` / `extras/fpm-saturation-monitor.sh:2` — `set -uo pipefail` without `-e`. Add `-e` or document why it's omitted.
- [ ] **[M6]** `extras/fleet-deploy.sh:83` — `[[ -z ... ]] && MANIFEST_FILE="$1" || { echo; exit 1 }` — SC2015 A&&B||C pattern. Rewrite as `if/else`.
- [ ] **[M7]** `website/restore:49` — `[[ -n ... ]] && ok ... || ok ...` — SC2015 pattern (benign here but inconsistent). Rewrite as `if/else`.
- [ ] **[M8]** `pi-image-backup.sh:36–76` — 40-line block of `DONE(...)` dev notes in the script header. Move to CHANGELOG, remove from script.
- [ ] **[M9]** `install.sh:529–532` — Same `&& ok || die` pattern for the non-`us-east-1` bucket-create branch (duplicate of H2).
- [ ] **[M10]** `pi-image-backup.sh:1265` — `FW_COMPRESSED_HUMAN` computed but never logged or used. Log it or remove it.

---

## 🔵 Low

- [ ] **[L1]** `extras/build-recovery-usb.sh:109` / `extras/build-netboot-image.sh:102,253` — `ls *.img | head -1` breaks on filenames with spaces. Replace with `find ... -name '*.img' | head -1`.
- [ ] **[L2]** `deploy-pi.sh:14` — `PI_DIR="~/pi2s3"` — tilde in double quotes doesn't expand locally. Use `PI_DIR=~/pi2s3` (no quotes).
- [ ] **[L3]** `extras/setup-netboot.sh:89` — `trap "rm -f '${TMPCONF}'" EXIT` with double quotes (SC2064). Add `# shellcheck disable=SC2064` comment since expansion-at-set-time is intentional here.
- [ ] **[L4]** `extras/setup-netboot.sh:57` — `echo "${CURRENT}" | sed 's/^/    /'` — sed where a bash loop or printf would do. Minor.
- [ ] **[L5]** `pi-image-backup.sh:1283` — `$(( TOTAL_USED_BYTES + EXTRA_PART_USED_B[$_ei] ))` — unnecessary `$` on arithmetic array index (SC2004). Use `EXTRA_PART_USED_B[_ei]`.
- [ ] **[L6]** `push.sh:28` — `@{u}` triggers SC1083 (literal braces false positive). Add `# shellcheck disable=SC1083` comment.

---

## Score summary

| Script | Crit | High | Med | Low | Grade |
|---|---|---|---|---|---|
| pi-image-restore.sh | 1 | 0 | 1 | 0 | F |
| install.sh | 0 | 3 | 3 | 0 | D |
| test-recovery.sh | 0 | 1 | 0 | 0 | D |
| website/restore | 0 | 1 | 0 | 0 | D |
| deploy-pi.sh | 0 | 0 | 1 | 1 | C |
| extras/fleet-deploy.sh | 0 | 0 | 2 | 0 | C |
| extras/cf-tunnel-watchdog.sh | 0 | 0 | 1 | 0 | C |
| extras/fpm-saturation-monitor.sh | 0 | 0 | 1 | 0 | C |
| extras/build-recovery-usb.sh | 0 | 0 | 1 | 1 | C |
| extras/build-netboot-image.sh | 0 | 0 | 1 | 2 | C |
| pi-image-backup.sh | 0 | 0 | 2 | 1 | C |
| extras/setup-netboot.sh | 0 | 0 | 0 | 2 | B |
| push.sh | 0 | 0 | 0 | 1 | B |
| pi2s3-heartbeat.sh | 0 | 0 | 0 | 0 | A |
| pi2s3-post-backup-check.sh | 0 | 0 | 0 | 0 | A |
| extras/recovery-launcher.sh | 0 | 0 | 0 | 0 | A |
| extras/post-restore-example.sh | 0 | 0 | 0 | 0 | A |
| extras/fleet-example/…/classroom.sh | 0 | 0 | 0 | 0 | A |
| lib/log.sh | 0 | 0 | 0 | 0 | A |
| lib/aws.sh | 0 | 0 | 0 | 0 | A |
| lib/containers.sh | 0 | 0 | 0 | 0 | A |
| website/install | 0 | 0 | 0 | 0 | A |
