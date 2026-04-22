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

## config.env.example

Full config for both extras. Copy the relevant section into your `~/pi2s3/config.env`.
