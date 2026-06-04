#!/usr/bin/env bash
#
# Fleet heartbeat sender — runs on each laptop, once per bot, every few minutes.
#
# It does the bot's own self-checks against Telegram and POSTs the result to the
# watchdog on Unraid. The key check is the SEND PROBE: it sends a message to a
# dedicated PROBE CHANNEL (a private, muted channel that exists only for these
# heartbeats), proving the bot can actually post on Telegram — catches token
# revoked / rate-limited / Telegram down, failures that getMe alone misses.
#
# Why a probe channel and not the bot's real chat: the message is NOT deleted,
# so probing the real chat would clutter it. A shared probe channel you mute
# and never read keeps real chats clean. (Trade-off: this proves the bot can
# send *somewhere*, not specifically to its real chat — it won't catch the bot
# being kicked from one particular real chat. Every other failure mode is the
# same signal.)
#
# Requires: bash, curl. (No python, no jq.)
#
# Configure via environment (e.g. in a systemd unit or cron wrapper):
#   BOT_ID        stable id matching registry.yaml, e.g. "brigitte"            (required)
#   BOT_TOKEN     the MONITORED bot's own Telegram token                       (required)
#   PROBE_CHAT    chat id of the shared probe channel the bot posts to         (required)
#   WATCHDOG_URL  e.g. http://192.168.1.11:9099/beat                           (required)
#   BACKEND_URL   optional: model backend health url to probe (Ollama/Audrey)
#   HOST_LABEL    optional: machine name for the alert text (default: hostname)
#
# Exit code is always 0 so a cron/timer wrapper never spams its own mail.

set -u

# Timestamped stderr logger. Every failure path logs through this so a bad
# scheduled run leaves a trail in StandardErrorPath (the .err file) instead of
# an empty file — an empty .err next to a nonzero exit is the single hardest
# thing to diagnose in this script's history.
log() { printf '%s heartbeat[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BOT_ID:-?}" "$*" >&2; }

# Required config. Don't use `: "${VAR:?}"` — under `set -u` that aborts the
# script with a nonzero exit BEFORE the `exit 0` contract at the bottom applies,
# which is exactly how this script paged the fleet once (launchd recorded a bare
# exit 78 / EX_CONFIG with an EMPTY .err — no clue what was wrong). Instead we
# collect what's missing, log it loudly, and still POST a heartbeat below so the
# hub can surface the misconfig via send_error rather than just going stale.
config_error=""
for _v in BOT_ID BOT_TOKEN PROBE_CHAT WATCHDOG_URL; do
  if [ -z "${!_v:-}" ]; then
    config_error="${config_error:+${config_error}, }${_v} unset"
  fi
done
if [ -n "${config_error}" ]; then
  log "CONFIG ERROR: ${config_error} — check the per-bot wrapper/env file"
  # Without WATCHDOG_URL we can't even report; log and bow out (still exit 0 so
  # the scheduler doesn't spam its own mail — the empty/loud .err is the signal).
  if [ -z "${WATCHDOG_URL:-}" ]; then
    log "WATCHDOG_URL unset — cannot report to hub; giving up this run"
    exit 0
  fi
fi

# Normalize every var the rest of the script dereferences, so a PARTIAL config
# error (some set, some not) can't trip `set -u` downstream and abort before the
# exit-0 contract. BOT_ID is needed for the payload; default it so we never
# unbound-var here. The config_error string already captured what's missing.
BOT_ID="${BOT_ID:-unknown}"
BOT_TOKEN="${BOT_TOKEN:-}"
PROBE_CHAT="${PROBE_CHAT:-}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"
API="https://api.telegram.org/bot${BOT_TOKEN}"

getme_ok=true
send_ok=true
send_error=""
backend_ok=true

# A partial config error (something missing, but WATCHDOG_URL present so we can
# still report) surfaces to the hub as a send_error rather than vanishing. Skip
# the Telegram probes entirely — they'd just fail against a half-built API URL —
# and go straight to reporting the misconfig to the hub.
if [ -n "${config_error}" ]; then
  send_ok=false
  getme_ok=false
  send_error="config: ${config_error}"
fi

# --- getMe: token valid + Telegram reachable -------------------------------
# Skip when config is broken (getme_ok already false) — nothing to learn here.
if [ -z "${config_error}" ] && ! curl -fsS --max-time 10 "${API}/getMe" >/dev/null 2>&1; then
  getme_ok=false
  log "getMe failed — token invalid or Telegram unreachable"
fi

# --- send probe: post to the shared probe channel (no delete) ---------------
# The message names the bot + host so a shared channel stays legible. We mute
# the channel and never read it; the messages just accumulate harmlessly.
# Only attempt if getMe passed (no point if Telegram is unreachable).
if [ "${getme_ok}" = "true" ]; then
  probe_text="🩺 ${BOT_ID}@${HOST_LABEL} $(date -u +%H:%M:%SZ)"
  resp="$(curl -fsS --max-time 15 -G "${API}/sendMessage" \
            --data-urlencode "chat_id=${PROBE_CHAT}" \
            --data-urlencode "text=${probe_text}" \
            --data-urlencode "disable_notification=true" 2>/dev/null)"
  rc=$?
  if [ ${rc} -ne 0 ] || [ -z "${resp}" ]; then
    send_ok=false
    send_error="sendMessage transport error (rc=${rc})"
    log "send probe transport error (curl rc=${rc}) — Telegram unreachable mid-send"
  elif printf '%s' "${resp}" | grep -q '"ok":true'; then
    : # posted fine — nothing to clean up, the message stays in the probe channel
  else
    # Telegram returned ok:false — pull the human-readable reason.
    send_ok=false
    send_error="$(printf '%s' "${resp}" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//; s/"$//')"
    [ -z "${send_error}" ] && send_error="sendMessage rejected"
    log "send probe rejected: ${send_error}"
  fi
fi

# --- optional backend probe ------------------------------------------------
if [ -n "${BACKEND_URL:-}" ]; then
  if ! curl -fsS --max-time 8 "${BACKEND_URL}" >/dev/null 2>&1; then
    backend_ok=false
    log "backend probe failed: ${BACKEND_URL} unreachable"
  fi
fi

# --- POST the heartbeat ----------------------------------------------------
# Escape send_error for JSON (quotes/backslashes) — keep it simple.
esc_error="$(printf '%s' "${send_error}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
if [ -n "${send_error}" ]; then
  send_error_json="\"${esc_error}\""
else
  send_error_json="null"
fi

payload=$(cat <<EOF
{"bot":"${BOT_ID}","host":"${HOST_LABEL}","getme_ok":${getme_ok},"send_ok":${send_ok},"send_error":${send_error_json},"backend_ok":${backend_ok}}
EOF
)

# Retry the hub POST a few times. A single transient LAN blip (Wi-Fi reassoc,
# brief route flap) shouldn't cost a whole 5-min beat — two dropped beats in a
# row is what trips the hub's stale_after and pages you. 3 attempts with a short
# backoff comfortably outlasts a momentary blip while staying well inside the
# 300s interval. Still exit 0 regardless (the scheduler must never spam mail).
posted=false
for _attempt in 1 2 3; do
  if curl -fsS --max-time 10 -X POST "${WATCHDOG_URL}" \
       -H "Content-Type: application/json" \
       -d "${payload}" >/dev/null 2>&1; then
    posted=true
    break
  fi
  [ "${_attempt}" -lt 3 ] && sleep 3
done
if [ "${posted}" != "true" ]; then
  log "could not reach hub at ${WATCHDOG_URL} after 3 attempts — beat not delivered this run"
fi

exit 0
