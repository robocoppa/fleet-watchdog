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

The `send_ok` check is a **real `sendMessage` to a shared, muted probe
channel** (not deleted) — so it proves the bot can actually post on Telegram
without cluttering any real chat. `getMe` alone would *not* catch a
rate-limited or restricted bot; the send probe does.

> Note: this proves the bot can send *somewhere*, not specifically to its real
> chat — it won't catch the bot being kicked from one particular real chat.
> Every other failure mode (token revoked, rate-limited, Telegram down, daemon
> dead) produces the same signal. Posting to a muted probe channel was chosen
> over send-to-real-chat-then-delete to keep real chats free of probe spam.

## Architecture

```
each laptop, per bot                          Unraid hub (always on)
┌───────────────────────────┐                ┌──────────────────────────────┐
│ heartbeat.sh (timer/cron)  │                │ fleet-watchdog container :9099 │
│  • getMe self-check        │   POST /beat   │  • records last-seen per bot   │
│  • send probe → probe chan │ ─────JSON────► │  • watchdog loop every 60s:    │
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

One sender per bot. Requires only `bash` + `curl`. **Clone the repo once on the
machine in a dir you own** (e.g. `~/fleet-watchdog`) — the schedulers run
`heartbeat.sh` straight from that checkout (no `/usr/local/bin` copy), so the
self-updater (next section) keeps the live script current with a plain
`git pull`.

```bash
cd ~ && git clone https://github.com/robocoppa/fleet-watchdog.git
```

**systemd (recommended for always-on daemons):**

```bash
sudo cp ~/fleet-watchdog/heartbeat/fleet-heartbeat@.service heartbeat/fleet-heartbeat@.timer /etc/systemd/system/
sudo $EDITOR /etc/systemd/system/fleet-heartbeat@.service   # set User=/Group= and the ExecStart path to your login user
sudo mkdir -p /etc/fleet-heartbeat
sudo cp ~/fleet-watchdog/heartbeat/env.example /etc/fleet-heartbeat/hermes-claudette.env
sudo $EDITOR /etc/fleet-heartbeat/hermes-claudette.env   # set BOT_ID/TOKEN/PROBE_CHAT/WATCHDOG_URL
sudo chmod 600 /etc/fleet-heartbeat/hermes-claudette.env
sudo systemctl enable --now fleet-heartbeat@hermes-claudette.timer
```

The unit is a system unit but `User=`/`Group=` run the beat as the checkout
owner, so it and the (`--user`) self-updater share one tree. The instance name
after `@` is the bot id and selects its env file — one timer per bot.

**cron / launchd (Mac):** edit `heartbeat/cron-wrapper.sh` into
`~/.fleet-heartbeat/<bot>.sh` (it execs `heartbeat.sh` from the checkout), then
point cron or a launchd plist at that wrapper. See the Mac runbook for launchd.

The `BOT_ID` in each env file **must match** the id in `registry.yaml`.

### 5. Auto-update the fleet (optional but recommended)

Because senders run `heartbeat.sh` *from the checkout*, a self-updater that
pulls the checkout is the entire deploy — no reinstall, no `sudo` to ship code.
Each host runs `heartbeat/fleet-update.sh` on a slow (~15 min) timer; it
converges the checkout onto the **`released` git tag** and validates the
incoming `heartbeat.sh` with `bash -n` before switching to it (a broken release
is refused, the host stays on the last good commit).

**Release model — the safety gate.** Push to `main` as often as you like;
nothing deploys. When a commit is fleet-ready, move the tag:

```bash
git tag -f released        # tag current HEAD as the release
git push -f origin released
```

Within ~15 min every host pulls that commit and its live `heartbeat.sh` updates.
A half-finished push to `main` never reaches the fleet — only the tag does.

Install the updater per machine (runs as **you**, on your user-owned checkout):

```bash
# Linux (systemd --user):
mkdir -p ~/.config/systemd/user
cp ~/fleet-watchdog/heartbeat/fleet-update.service heartbeat/fleet-update.timer ~/.config/systemd/user/
$EDITOR ~/.config/systemd/user/fleet-update.service   # FLEET_REPO_DIR if not ~/fleet-watchdog
systemctl --user daemon-reload && systemctl --user enable --now fleet-update.timer
sudo loginctl enable-linger $USER     # so it runs while you're logged out

# Mac (launchd): cp the example plist, edit the absolute paths, load it:
cp ~/fleet-watchdog/heartbeat/com.fleet-watchdog.update.plist.example \
   ~/Library/LaunchAgents/com.fleet-watchdog.update.plist
$EDITOR ~/Library/LaunchAgents/com.fleet-watchdog.update.plist   # set /Users/<you> paths
launchctl load ~/Library/LaunchAgents/com.fleet-watchdog.update.plist
```

Force an immediate poll: `systemctl --user start fleet-update` (Linux) or
`launchctl start com.fleet-watchdog.update` (Mac). The updater is silent when
already current; it logs every other outcome to its `.err`/journal.

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
