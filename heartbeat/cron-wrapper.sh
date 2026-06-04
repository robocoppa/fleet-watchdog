#!/usr/bin/env bash
# Per-bot wrapper: exports this bot's env, then execs the shared heartbeat.sh
# straight from the checkout. Used by launchd (Mac) and as a cron fallback.
#
# Install (one wrapper per bot, in a dir you own — it holds a token):
#   mkdir -p ~/.fleet-heartbeat
#   cp cron-wrapper.sh ~/.fleet-heartbeat/<bot>.sh   # then edit the vars below
#   chmod 700 ~/.fleet-heartbeat/<bot>.sh
#   # launchd: point the plist's ProgramArguments at this wrapper (absolute path)
#   # cron fallback:  crontab -e  →  */5 * * * * ~/.fleet-heartbeat/<bot>.sh
#
# The final line execs heartbeat.sh FROM THE CHECKOUT (no /usr/local/bin copy),
# so the self-updater's pull to the released tag is the whole deploy — nothing
# to reinstall. Edit FLEET_CHECKOUT if the repo isn't at ~/fleet-watchdog.

export BOT_ID="hermes-claudette"
export BOT_TOKEN="123456:ABC-the-monitored-bots-token"
export PROBE_CHAT="-1001234567890"   # shared muted probe channel
export WATCHDOG_URL="http://192.168.1.11:9099/beat"
export HOST_LABEL="claudette-laptop"
# export BACKEND_URL="http://192.168.1.11:11434/api/version"

# Path to the checkout's heartbeat.sh. MUST be ABSOLUTE — do NOT use $HOME here.
# launchd execs this wrapper in a stripped environment where $HOME is often
# UNSET, so "$HOME/fleet-watchdog" resolves to "/fleet-watchdog", the exec
# fails, and launchd reports exit 78 (EX_CONFIG) with an EMPTY .err because
# heartbeat.sh never starts. (This exact bug paged the fleet — caught 2026-06-04.)
# Set the literal path for THIS user/host; this file is already per-bot anyway.
FLEET_CHECKOUT="${FLEET_CHECKOUT:-/Users/CHANGE_ME/fleet-watchdog}"
exec "${FLEET_CHECKOUT}/heartbeat/heartbeat.sh"
