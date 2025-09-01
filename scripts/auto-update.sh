#!/usr/bin/env bash
# auto-update.sh: unattended system updates with Signal reporting (apt-only)
#
# What this does
# - Updates the system via apt-get in a non-interactive way
# - Builds a detailed summary (updated packages, still pending, problems, duration)
# - Sends the summary via signal-cli to one or more recipients
# - Optionally schedules a reboot if required by the system
#
# How to configure
# - Optional config file: /etc/auto-update/config or ./config/auto-update.conf
#   Variables:
#     SIGNAL_NUMBER         sender number registered with signal-cli
#     SIGNAL_RECIPIENTS     comma-separated recipients
#     DRY_RUN               "true" to simulate without changes (no root required)
#     REBOOT_IF_REQUIRED    "true" to reboot when /var/run/reboot-required exists
#     LOG_DIR               log directory (default /var/log/auto-update)
#     SIGNAL_LINUXUSER      the Linux user which can access signal-cli (used with su -c)
# - Environment variables with the same names can also be exported before running.
#
# Requirements
# - Debian/Ubuntu (apt-get available)
# - signal-cli installed and linked to SIGNAL_NUMBER (notifications are skipped if absent)
# - Run as root unless DRY_RUN=true
#
# Notes
# - This script is intentionally apt-only; other package managers are not supported.
# - Uses a lock to avoid concurrent runs.
set -euo pipefail

# Defaults
CONFIG_FILES=("/etc/auto-update/config" "./config/auto-update.conf")
LOCK_FILE="/var/lock/auto-update.lock"
LOG_DIR="/var/log/auto-update"
LOG_FILE="${LOG_DIR}/last-run.log"
SIGNAL_NUMBER=""        # sender registered with signal-cli
SIGNAL_RECIPIENTS=""    # comma-separated list of recipients
DRY_RUN="false"
REBOOT_IF_REQUIRED="true"
SIGNAL_LINUXUSER=""
DIST_UPGRADE="false"

# Load config if present
for cfg in "${CONFIG_FILES[@]}"; do
  if [[ -f "$cfg" ]]; then
    # shellcheck disable=SC1090
    source "$cfg"
  fi
done

mkdir -p "$LOG_DIR"

# Print to stdout and append to log file
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Send a message via signal-cli to all recipients (best-effort)
send_signal() {
  local message="$1"
  if [[ -z "$SIGNAL_NUMBER" || -z "$SIGNAL_RECIPIENTS" ]]; then
    log "signal-cli not configured (SIGNAL_NUMBER or SIGNAL_RECIPIENTS missing). Skipping notification."
    return 0
  fi
  if ! command -v signal-cli >/dev/null 2>&1; then
    log "signal-cli not found. Skipping notification."
    return 0
  fi
  # Expand backslash escapes like \n in the message
  msg_expanded="$(printf '%b' "$message")"

  IFS=',' read -r -a recips <<< "$SIGNAL_RECIPIENTS"
  for r in "${recips[@]}"; do
    # Use su -c to run as a Linux user that has working signal-cli config (if provided)
    su -c "signal-cli -u '${SIGNAL_NUMBER}' send -m '${msg_expanded}' '${r}' || log 'Failed to send signal to ${r}'" $SIGNAL_LINUXUSER
  done
}

# Create and hold an exclusive, non-blocking lock (fd 9)
acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Another update process is running. Exiting."
    exit 0
  fi
}

# Release the lock and remove the lock file
release_lock() {
  flock -u 9 || true
  rm -f "$LOCK_FILE" || true
}

trap 'release_lock' EXIT

# Require root unless DRY_RUN=true
if [[ "$DRY_RUN" != "true" && "$EUID" -ne 0 ]]; then
  echo "This script must be run as root unless DRY_RUN=true." >&2
  exit 1
fi

acquire_lock

START_TS=$(date +%s)
HOST="$(hostname)"
log "Starting auto-update on $HOST (dry-run=$DRY_RUN)"

UPDATED="false"
REBOOT_REQUIRED="false"
STATUS="success"
PROBLEMS=""
UPDATED_PKGS=()
PENDING_PKGS=()
NOT_UPDATED_PKGS=()

collect_problem() {
  local msg="$1"
  PROBLEMS+="$msg\n"
}

detect_errors_from_output() {
  local label="$1"; shift
  local out="$*"
  if echo "$out" | grep -qiE "(^|\b)(error|failed|conflict|broken|failure)(\b|:)"; then
    collect_problem "$label: $(echo "$out" | tail -n 10)"
  fi
}

# Helper per-PM discovery of pending updates before running
get_pending_updates() {
  # apt only
  apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst /{print $2}'
}

# Perform updates (apt only)

# Capture pending before run
mapfile -t PENDING_PKGS < <(get_pending_updates || true)
if [[ "$DRY_RUN" == "true" ]]; then
  apt-get -s update | tee -a "$LOG_FILE"
  if [[ "$DIST_UPGRADE" == "true" ]]; then
    apt-get -s dist-upgrade -y | tee -a "$LOG_FILE"
  else
    apt-get -s upgrade -y | tee -a "$LOG_FILE"
  fi
  mapfile -t PENDING_PKGS < <(get_pending_updates || true)
  UPDATED="false"
else
  DEBIAN_FRONTEND=noninteractive apt-get update | tee -a "$LOG_FILE" || collect_problem "apt-get update failed"
  UPG_OUT=$(DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade 2>&1 | tee -a "$LOG_FILE" || true)
  if echo "$UPG_OUT" | grep -qE "^\s*\d+ upgraded|^Inst "; then UPDATED="true"; fi
  detect_errors_from_output "apt dist-upgrade" "$UPG_OUT"
  while IFS= read -r line; do
    pkg=$(awk '{print $2}' <<<"$line")
    [[ -n "$pkg" ]] && UPDATED_PKGS+=("$pkg")
  done < <(echo "$UPG_OUT" | awk '/^Inst /')
  if [[ -f /var/run/reboot-required ]]; then REBOOT_REQUIRED="true"; fi
  if [[ ${#PENDING_PKGS[@]} -gt 0 ]]; then
    for p in "${PENDING_PKGS[@]}"; do
      if ! printf '%s\n' "${UPDATED_PKGS[@]}" | grep -qx "$p"; then NOT_UPDATED_PKGS+=("$p"); fi
    done
  fi
fi

END_TS=$(date +%s)
DURATION=$((END_TS-START_TS))

# Build detailed message
format_list() {
  local -n arr=$1
  local max=${2:-20}
  local n=${#arr[@]}
  if (( n==0 )); then echo "(none)"; return; fi
  if (( n<=max )); then printf '%s\n' "${arr[@]}" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'; else
    printf '%s\n' "${arr[@]:0:max}" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
    echo " and $((n-max)) more"
  fi
}

UPDATED_LIST=$(format_list UPDATED_PKGS 30)
NOT_UPDATED_LIST=$(format_list NOT_UPDATED_PKGS 30)
PENDING_LIST=$(format_list PENDING_PKGS 30)
PROBLEMS_TRIMMED=$(echo -e "$PROBLEMS" | sed '/^$/d' | head -n 20)

SUMMARY="Auto-update on ${HOST}\n\nUpdated: ${UPDATED}\nReboot required: ${REBOOT_REQUIRED}\nDuration: ${DURATION}s\n\nUpdated packages: ${UPDATED_LIST}\nNot updated (still pending): ${NOT_UPDATED_LIST}\nPending before run: ${PENDING_LIST}\n\nProblems:\n${PROBLEMS_TRIMMED:-none}\n\nLog: ${LOG_FILE}"
log "$SUMMARY"

send_signal "$SUMMARY"

# Optional: reboot
if [[ "$REBOOT_REQUIRED" == "true" && "$REBOOT_IF_REQUIRED" == "true" && "$DRY_RUN" != "true" ]]; then
  log "Reboot required. Rebooting in 1 minute..."
  send_signal "${HOST}: Reboot required after updates. Rebooting in 1 minute."
  shutdown -r +1 "Auto-update reboot"
fi

exit 0