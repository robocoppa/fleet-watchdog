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

: "${BOT_ID:?set BOT_ID}"
: "${BOT_TOKEN:?set BOT_TOKEN}"
: "${PROBE_CHAT:?set PROBE_CHAT}"
: "${WATCHDOG_URL:?set WATCHDOG_URL}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"
API="https://api.telegram.org/bot${BOT_TOKEN}"

getme_ok=true
send_ok=true
send_error=""
backend_ok=true

# --- getMe: token valid + Telegram reachable -------------------------------
if ! curl -fsS --max-time 10 "${API}/getMe" >/dev/null 2>&1; then
  getme_ok=false
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
  elif printf '%s' "${resp}" | grep -q '"ok":true'; then
    : # posted fine — nothing to clean up, the message stays in the probe channel
  else
    # Telegram returned ok:false — pull the human-readable reason.
    send_ok=false
    send_error="$(printf '%s' "${resp}" | grep -o '"description":"[^"]*"' | head -1 | sed 's/"description":"//; s/"$//')"
    [ -z "${send_error}" ] && send_error="sendMessage rejected"
  fi
fi

# --- optional backend probe ------------------------------------------------
if [ -n "${BACKEND_URL:-}" ]; then
  curl -fsS --max-time 8 "${BACKEND_URL}" >/dev/null 2>&1 || backend_ok=false
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

curl -fsS --max-time 10 -X POST "${WATCHDOG_URL}" \
  -H "Content-Type: application/json" \
  -d "${payload}" >/dev/null 2>&1 || true

exit 0
