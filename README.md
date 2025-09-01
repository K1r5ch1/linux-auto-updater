# Linux Auto Update (apt) with Signal Reports

> **WARNING**: This repo was written with the help of AI, everything runs fine in my test and i have checked the code
> for errors and bugs but i can't guarantee that it is 100% safe.

This project provides a Bash script to run unattended system updates on Debian/Ubuntu (apt only) and send a detailed report via signal-cli. It also ships a systemd service and timer to run the updater automatically on a schedule.

Highlights:
- apt-only updates (safe, non-interactive)
- Detailed Signal message: updated packages, not updated (still pending), problems, duration
- Locking to avoid concurrent runs
- Logging to /var/log/auto-update/last-run.log
- Optional automatic reboot when required

## Files
- scripts/auto-update.sh — main update script (Bash)
- config/auto-update.conf.sample — sample config for the Bash script
- systemd/auto-update.service — systemd service
- systemd/auto-update.timer — systemd timer (daily)

## Requirements
- Debian/Ubuntu (apt)
- signal-cli installed and registered for the sending number (installation guide: https://github.com/AsamK/signal-cli/wiki/Quickstart)

## Install
1. Install the script:
   ```bash
   sudo install -Dm755 scripts/auto-update.sh /usr/local/bin/auto-update.sh
   ```
2. Configure via file (recommended):
   ```bash
   sudo install -d /etc/auto-update
   sudo install -m644 config/auto-update.conf.sample /etc/auto-update/config
   sudo editor /etc/auto-update/config
   # Set SIGNAL_NUMBER, SIGNAL_RECIPIENTS, and other options
   ```
3. Install systemd units and enable timer:
   ```bash
   sudo install -m644 systemd/auto-update.service /etc/systemd/system/auto-update.service
   sudo install -m644 systemd/auto-update.timer /etc/systemd/system/auto-update.timer
   sudo systemctl daemon-reload
   sudo systemctl enable --now auto-update.timer
   ```
4. Manual test:
   ```bash
   sudo /usr/local/bin/auto-update.sh
   # Dry-run (no changes):
   sudo env DRY_RUN=true /usr/local/bin/auto-update.sh
   ```

## Notes
- apt only; other package managers are not supported.
- Reboot requirement is detected via /var/run/reboot-required on apt systems.
- If signal-cli is missing or not configured, updates still run; only notifications are skipped.

## Security and Safety
- Requires root unless DRY_RUN=true.
- Uses a lock file at /var/lock/auto-update.lock to prevent concurrent runs.
- Consider adjusting Nice/IO scheduling in the service unit if needed.

## Uninstall
```bash
sudo systemctl disable --now auto-update.timer
sudo rm -f /etc/systemd/system/auto-update.service /etc/systemd/system/auto-update.timer
sudo rm -rf /etc/auto-update
sudo rm -f /usr/local/bin/auto-update.sh
sudo rm -rf /var/log/auto-update
```
