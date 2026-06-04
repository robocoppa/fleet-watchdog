#!/usr/bin/env bash
# Cron alternative to the systemd timer, for laptops where cron is simpler.
#
# Install:
#   cp heartbeat.sh /usr/local/bin/fleet-heartbeat.sh && chmod +x $_
#   cp cron-wrapper.sh /usr/local/bin/fleet-heartbeat-<bot>.sh   # edit vars below
#   crontab -e  →  */5 * * * * /usr/local/bin/fleet-heartbeat-<bot>.sh
#
# One wrapper per bot. Edit the vars, point at heartbeat.sh.

export BOT_ID="hermes-claudette"
export BOT_TOKEN="123456:ABC-the-monitored-bots-token"
export PROBE_CHAT="-1001234567890"   # shared muted probe channel
export WATCHDOG_URL="http://192.168.1.11:9099/beat"
export HOST_LABEL="claudette-laptop"
# export BACKEND_URL="http://192.168.1.11:11434/api/version"

exec /usr/local/bin/fleet-heartbeat.sh
