#!/usr/bin/env bash
#
# Heartbeat LOOP wrapper — for macOS/launchd KeepAlive jobs (and anywhere a
# long-running daemon is preferable to a scheduler).
#
# WHY THIS EXISTS: macOS launchd's `StartInterval` is a loose, power-managed
# scheduler. On an idle Mac it coalesces/throttles interval jobs hard — observed
# firing a "180s" heartbeat only every ~18 min on a Mac mini, which overran the
# hub's stale_after and caused false 🔴 pages. The fix is to STOP asking launchd
# to schedule us and instead run as a KeepAlive daemon: launchd keeps this
# process ALIVE (restarting it if it dies), and WE control cadence with an
# honest `sleep`. No coalescing, no throttling — the sleep is the sleep.
#
# It runs heartbeat.sh once per iteration as a fresh subprocess (not sourced),
# so the one-shot's `set -u` / early `exit` can't kill the loop, and each beat
# starts from a clean state.
#
# Config: same env as heartbeat.sh (BOT_ID/BOT_TOKEN/PROBE_CHAT/WATCHDOG_URL,
# optional HOST_LABEL/BACKEND_URL), PLUS:
#   BEAT_INTERVAL   seconds between beats (default 300 = 5 min)
#   FLEET_CHECKOUT  path to the checkout (default: this script's own dir's repo)
#
# Install (macOS, KeepAlive LaunchAgent) — see
# com.fleet-watchdog.heartbeat-keepalive.plist.example. The per-bot wrapper
# (~/.fleet-heartbeat/<bot>.sh) should `exec` THIS script instead of heartbeat.sh
# when using the keep-alive model.

set -u

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

log() { printf '%s heartbeat-loop[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BOT_ID:-?}" "$*" >&2; }

BEAT_INTERVAL="${BEAT_INTERVAL:-300}"

# Locate heartbeat.sh next to this script, so the loop always calls the
# same-checkout one-shot (self-updater keeps it current).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HEARTBEAT="${SCRIPT_DIR}/heartbeat.sh"
if [ ! -x "${HEARTBEAT}" ]; then
  log "cannot find executable heartbeat.sh at ${HEARTBEAT} — exiting (KeepAlive will retry)"
  # Sleep before exiting so a misconfig doesn't spin launchd in a tight respawn
  # loop (KeepAlive restarts us immediately on exit).
  sleep 30
  exit 1
fi

log "starting heartbeat loop: every ${BEAT_INTERVAL}s via ${HEARTBEAT}"

# Beat immediately on start (don't wait one interval), then loop. The one-shot
# always exits 0 by design; we don't gate the loop on its exit code.
while true; do
  "${HEARTBEAT}" || log "heartbeat.sh returned non-zero ($?) — continuing loop"
  sleep "${BEAT_INTERVAL}"
done
