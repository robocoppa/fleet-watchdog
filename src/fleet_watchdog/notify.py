"""Telegram alerting via the dedicated *watcher* bot.

This bot exists only to tell you when a monitored bot is in trouble. It must be
a separate bot from the ones being monitored — if a monitored bot is down, it
obviously can't deliver its own down-alert. Make one with @BotFather, then set
WATCHDOG_TOKEN + WATCHDOG_CHAT_ID.

If those env vars are unset, alerts are logged instead of sent, so the service
still runs (and /status still works) before you've wired the bot.
"""

from __future__ import annotations

import logging

import httpx

log = logging.getLogger("fleet_watchdog.notify")


class Notifier:
    def __init__(self, token: str | None, chat_id: str | None) -> None:
        self._token = token
        self._chat_id = chat_id
        self._client = httpx.AsyncClient(timeout=10.0)

    @property
    def enabled(self) -> bool:
        return bool(self._token and self._chat_id)

    async def send(self, text: str) -> None:
        if not self.enabled:
            log.warning("[alert — telegram not configured] %s", text)
            return
        url = f"https://api.telegram.org/bot{self._token}/sendMessage"
        try:
            resp = await self._client.post(
                url,
                json={
                    "chat_id": self._chat_id,
                    "text": text,
                    "parse_mode": "HTML",
                    "disable_web_page_preview": True,
                },
            )
            if resp.status_code != 200:
                # The watcher bot itself failing to send is logged loudly — it's
                # the one path with no fallback channel.
                log.error("watcher sendMessage failed %s: %s", resp.status_code, resp.text)
        except httpx.HTTPError as exc:
            log.error("watcher sendMessage error: %s", exc)

    async def aclose(self) -> None:
        await self._client.aclose()
