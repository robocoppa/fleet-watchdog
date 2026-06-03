"""Per-bot tier configuration.

The registry says which bots you *expect* to be up and how patient to be with
each. A roaming laptop you treat as transient gets ``expected_up: false`` so it
goes quiet when it sleeps instead of nagging you. An always-on bot gets a tight
``stale_after``.

Bots that heartbeat but aren't in the registry are still tracked (and shown in
/status); they fall back to ``WATCHDOG_DEFAULT_STALE`` and are treated as
expected-up, so a typo in a bot id surfaces as an alert rather than silence.

The file is re-read on each watchdog tick, so editing registry.yaml takes
effect without a restart.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import yaml

log = logging.getLogger("fleet_watchdog.registry")


@dataclass(frozen=True)
class BotPolicy:
    expected_up: bool
    stale_after: int
    # When true, also alert if send_ok / getme_ok / backend_ok report false.
    # Defaults true: a bot that can't send on Telegram is the whole point.
    alert_on_send_fail: bool
    alert_on_token_fail: bool
    alert_on_backend_fail: bool


def _coerce(entry: dict, default_stale: int) -> BotPolicy:
    return BotPolicy(
        expected_up=bool(entry.get("expected_up", True)),
        stale_after=int(entry.get("stale_after", default_stale)),
        alert_on_send_fail=bool(entry.get("alert_on_send_fail", True)),
        alert_on_token_fail=bool(entry.get("alert_on_token_fail", True)),
        alert_on_backend_fail=bool(entry.get("alert_on_backend_fail", False)),
    )


class Registry:
    """Loads registry.yaml on demand. Missing file is tolerated (all defaults)."""

    def __init__(self, path: str, default_stale: int) -> None:
        self._path = Path(path)
        self._default_stale = default_stale

    def policy_for(self, bot: str) -> BotPolicy:
        bots = self._load()
        entry = bots.get(bot, {})
        return _coerce(entry, self._default_stale)

    def known_bots(self) -> set[str]:
        return set(self._load().keys())

    def _load(self) -> dict[str, dict]:
        if not self._path.exists():
            return {}
        try:
            data = yaml.safe_load(self._path.read_text()) or {}
        except yaml.YAMLError as exc:
            log.warning("registry.yaml parse error, treating as empty: %s", exc)
            return {}
        bots = data.get("bots", {})
        return bots if isinstance(bots, dict) else {}
