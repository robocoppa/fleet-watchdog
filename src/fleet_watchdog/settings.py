"""Runtime settings for the fleet watchdog.

Secrets and per-deployment paths come from the environment; the per-bot
registry (which bots exist, their tiers, their staleness thresholds) lives in
a YAML file so you can add a laptop without redeploying the container.

    Environment knobs:
      WATCHDOG_TOKEN        Telegram bot token for the *watcher* bot (the one
                            that sends you alerts). Make a fresh bot with
                            @BotFather — do NOT reuse a monitored bot's token,
                            or a down bot can't tell you it's down.
      WATCHDOG_CHAT_ID      Your Telegram chat id (where alerts are delivered).
      WATCHDOG_REGISTRY     Path to registry.yaml. Default /config/registry.yaml.
      WATCHDOG_STATE        Path to the persisted last-seen JSON. Default
                            /data/state.json.
      WATCHDOG_HOST         Bind host. Default 0.0.0.0.
      WATCHDOG_PORT         Bind port. Default 9099.
      WATCHDOG_DEFAULT_STALE  Fallback stale_after (seconds) for bots not
                            listed in the registry. Default 700 (two missed
                            5-min beats).
      WATCHDOG_TICK         Watchdog loop interval (seconds). Default 60.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    token: str | None
    chat_id: str | None
    registry_path: str
    state_path: str
    host: str
    port: int
    default_stale_after: int
    tick_seconds: int

    @property
    def telegram_configured(self) -> bool:
        return bool(self.token and self.chat_id)


def load_settings() -> Settings:
    return Settings(
        token=os.getenv("WATCHDOG_TOKEN") or None,
        chat_id=os.getenv("WATCHDOG_CHAT_ID") or None,
        registry_path=os.getenv("WATCHDOG_REGISTRY", "/config/registry.yaml"),
        state_path=os.getenv("WATCHDOG_STATE", "/data/state.json"),
        host=os.getenv("WATCHDOG_HOST", "0.0.0.0"),
        port=int(os.getenv("WATCHDOG_PORT", "9099")),
        default_stale_after=int(os.getenv("WATCHDOG_DEFAULT_STALE", "700")),
        tick_seconds=int(os.getenv("WATCHDOG_TICK", "60")),
    )
