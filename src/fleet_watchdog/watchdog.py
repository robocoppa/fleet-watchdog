"""The watchdog loop: decide each bot's health and alert on transitions.

Health is collapsed into a single state string per bot so alerting is a clean
edge-trigger — we alert once when a bot enters a bad state and once when it
recovers, never every tick. Priority order matters: a stale bot can't have a
fresh send_ok, so staleness wins.

    "ok"           healthy, fresh, sending
    "stale"        no heartbeat within stale_after (machine/daemon down)
    "send_fail"    heartbeating but its last sendMessage probe failed
    "token_fail"   heartbeating but getMe failed (token revoked / TG outage)
    "backend_fail" heartbeating but model backend unreachable

``expected_up: false`` bots never go to "stale" (a sleeping laptop is not an
incident) but DO still report send/token failures while they are awake and
beating — because if a transient bot beats at all, it's running, and a running
bot that can't send is worth knowing about if you opted in.
"""

from __future__ import annotations

import asyncio
import logging
import time

from .models import BotState
from .notify import Notifier
from .registry import BotPolicy, Registry
from .store import FleetStore

log = logging.getLogger("fleet_watchdog.watchdog")


def evaluate(bot: BotState, policy: BotPolicy, now: float) -> str:
    """Pure: return the health state for one bot. No I/O, fully testable."""
    age = now - bot.last_seen
    if age > policy.stale_after:
        # A transient laptop going quiet is expected, not an incident.
        return "ok" if not policy.expected_up else "stale"
    # Bot is fresh — now grade the Telegram-facing self-checks it reported.
    if not bot.getme_ok and policy.alert_on_token_fail:
        return "token_fail"
    if not bot.send_ok and policy.alert_on_send_fail:
        return "send_fail"
    if not bot.backend_ok and policy.alert_on_backend_fail:
        return "backend_fail"
    return "ok"


def _down_message(bot: BotState, state: str, now: float) -> str:
    age = int(now - bot.last_seen)
    host = f"<code>{bot.host}</code>"
    if state == "stale":
        return (
            f"🔴 <b>{bot.bot}</b> is DOWN\n"
            f"Host: {host}\n"
            f"No heartbeat for {age}s (machine or daemon down)."
        )
    if state == "send_fail":
        why = bot.send_error or "unknown error"
        return (
            f"🟠 <b>{bot.bot}</b> can't send on Telegram\n"
            f"Host: {host}\n"
            f"Process is alive and beating, but its sendMessage probe failed: "
            f"<code>{why}</code>"
        )
    if state == "token_fail":
        return (
            f"🟠 <b>{bot.bot}</b> token/Telegram problem\n"
            f"Host: {host}\n"
            f"getMe failed — token revoked or Telegram unreachable."
        )
    if state == "backend_fail":
        return (
            f"🟠 <b>{bot.bot}</b> model backend unreachable\n"
            f"Host: {host}\n"
            f"Bot is up but its model backend (Ollama/Audrey) isn't answering."
        )
    return f"⚠️ <b>{bot.bot}</b> entered state {state}"


def _recovery_message(bot: BotState, prev_state: str) -> str:
    return (
        f"✅ <b>{bot.bot}</b> recovered\n"
        f"Host: <code>{bot.host}</code>\n"
        f"Was: {prev_state}. Now healthy and sending."
    )


class Watchdog:
    def __init__(self, store: FleetStore, registry: Registry, notifier: Notifier, tick: int) -> None:
        self._store = store
        self._registry = registry
        self._notifier = notifier
        self._tick = tick

    async def run(self) -> None:
        log.info("watchdog loop started (tick=%ds)", self._tick)
        while True:
            try:
                await self.tick_once()
            except Exception:  # noqa: BLE001 — loop must never die
                log.exception("watchdog tick failed")
            await asyncio.sleep(self._tick)

    async def tick_once(self) -> None:
        now = time.time()
        for bot in self._store.all():
            policy = self._registry.policy_for(bot.bot)
            new_state = evaluate(bot, policy, now)
            prev_state = bot.alerted_state
            if new_state == prev_state:
                continue
            # Edge transition — alert and remember.
            if new_state == "ok":
                await self._notifier.send(_recovery_message(bot, prev_state))
            else:
                await self._notifier.send(_down_message(bot, new_state, now))
            self._store.set_alerted_state(bot.bot, new_state)
