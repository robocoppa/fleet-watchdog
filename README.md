# fleet-watchdog

A push-based heartbeat watchdog for a small fleet of LAN bots (OpenClaw,
Hermes, anything that talks to Telegram). One always-on hub (your Unraid box)
watches for trouble and DMs you on Telegram when a bot goes dark — including the
case where a bot is still running but **can no longer send messages** on
Telegram.

## Why push, not poll

The bots run on laptops that come and go (sleep, roam, shut down). The hub never
tries to reach them — each bot **pushes** a heartbeat to the hub every couple of
minutes. A sleeping laptop simply stops beating; a bot you've marked
`expected_up` going quiet is what triggers an alert. No SMB mounts, no SSH, no
chasing changing IPs.

## What "the bot is alive" means here

Each heartbeat carries the result of the bot's own self-checks, so you get three
distinct failure signals — not just "is the box on":

| Signal in heartbeat | Catches |
|---|---|
| heartbeat stops arriving | machine powered off / asleep, or the daemon crashed |
| `send_ok: false` | **bot is running but can't post to its chat** — blocked, kicked, chat migrated, rate-limited |
| `getme_ok: false` | token revoked, or Telegram itself unreachable |
| `backend_ok: false` (opt-in) | model backend (Ollama/Audrey) down |

The `send_ok` check is a **real `sendMessage` to the bot's actual target chat,
immediately deleted** — so it proves end-to-end send capability against the chat
that matters, without leaving spam. `getMe` alone would *not* catch a
blocked/kicked bot; the send probe does.

## Architecture

```
each laptop, per bot                          Unraid hub (always on)
┌───────────────────────────┐                ┌──────────────────────────────┐
│ heartbeat.sh (timer/cron)  │                │ fleet-watchdog container :9099 │
│  • getMe self-check        │   POST /beat   │  • records last-seen per bot   │
│  • sendMessage+delete probe │ ─────JSON────► │  • watchdog loop every 60s:    │
│  • optional backend probe  │                │     stale / send_fail /        │
│  POSTs {bot,host,send_ok,  │                │     token_fail / backend_fail  │
│         send_error,...}     │                │  • edge-triggered Telegram     │
└───────────────────────────┘                │     alert via WATCHER bot      │
                                              └──────────────────────────────┘
                                                          │
                                                  🔴/🟠/✅ DM to you
```

Alerts are **edge-triggered**: one message when a bot enters a bad state, one
when it recovers. No per-tick spam. State is persisted to JSON so a container
restart doesn't replay old alerts.

## Setup

### 1. Make a dedicated *watcher* bot

Create a **new** Telegram bot with [@BotFather](https://t.me/BotFather)
(`/newbot`). This bot exists only to send you alerts — it must be separate from
the bots being monitored, because a down bot can't deliver its own alert. DM the
new bot once, then read your chat id from
`https://api.telegram.org/bot<TOKEN>/getUpdates`.

### 2. Deploy the hub on Unraid

```bash
# Put this repo at /mnt/user/appdata/fleet-watchdog
cd /mnt/user/appdata/fleet-watchdog
cp .env.example .env          # fill WATCHDOG_TOKEN + WATCHDOG_CHAT_ID
$EDITOR registry.yaml         # list your bots + tiers (see below)
docker compose up -d --build
```

The container joins the external `ollama-net` and publishes `:9099` on the LAN
so laptops can POST to `http://192.168.1.11:9099/beat`. Check the fleet any time
at `http://192.168.1.11:9099/status`.

### 3. The registry (`registry.yaml`)

Lists which bots you expect to be up and how patient to be with each. Re-read on
every tick — edit it without restarting. A roaming laptop gets
`expected_up: false` so it goes quiet when asleep instead of nagging you. See
the comments in [registry.yaml](registry.yaml) for all keys.

### 4. Install the heartbeat sender on each laptop

One sender per bot. Requires only `bash` + `curl`.

**systemd (recommended for always-on daemons):**

```bash
sudo cp heartbeat/heartbeat.sh /usr/local/bin/fleet-heartbeat.sh
sudo chmod +x /usr/local/bin/fleet-heartbeat.sh
sudo cp heartbeat/fleet-heartbeat@.service heartbeat/fleet-heartbeat@.timer /etc/systemd/system/
sudo mkdir -p /etc/fleet-heartbeat
sudo cp heartbeat/env.example /etc/fleet-heartbeat/hermes-claudette.env
sudo $EDITOR /etc/fleet-heartbeat/hermes-claudette.env   # set BOT_ID/TOKEN/TARGET_CHAT/WATCHDOG_URL
sudo chmod 600 /etc/fleet-heartbeat/hermes-claudette.env
sudo systemctl enable --now fleet-heartbeat@hermes-claudette.timer
```

The instance name after `@` is the bot id and selects its env file, so you run
one timer per bot. Add another bot by dropping a second `.env` and enabling a
second timer instance.

**cron (simpler laptops):** edit and install `heartbeat/cron-wrapper.sh`, then
`*/2 * * * * /usr/local/bin/fleet-heartbeat-<bot>.sh`.

The `BOT_ID` in each env file **must match** the id in `registry.yaml`.

## Local development

```bash
uv venv && uv pip install -e ".[dev]"
.venv/bin/pytest tests/ -q
.venv/bin/ruff check .
.venv/bin/fleet-watchdog          # runs on :9099; alerts log if no token set
```

## Endpoints

- `POST /beat` — heartbeat intake (the only write path).
- `GET /status` — current fleet table as JSON.
- `GET /healthz` — container liveness.
