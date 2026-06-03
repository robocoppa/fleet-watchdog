"""In-memory fleet state with JSON persistence.

The receiver writes heartbeats here; the watchdog loop reads them. State is
mirrored to a JSON file so a container restart doesn't reset every bot to
"unknown" (which would otherwise fire a false recovery alert once each bot
beats again). Writes are cheap and infrequent (one per heartbeat), so a plain
dump-on-write is fine.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from .models import BotState, Heartbeat

log = logging.getLogger("fleet_watchdog.store")


class FleetStore:
    def __init__(self, state_path: str) -> None:
        self._path = Path(state_path)
        self._bots: dict[str, BotState] = {}
        self._load()

    def record(self, hb: Heartbeat) -> None:
        """Apply an inbound heartbeat. Preserves alerted_state for edge logic."""
        prev = self._bots.get(hb.bot)
        self._bots[hb.bot] = BotState(
            bot=hb.bot,
            host=hb.host,
            last_seen=time.time(),
            getme_ok=hb.getme_ok,
            send_ok=hb.send_ok,
            send_error=hb.send_error,
            backend_ok=hb.backend_ok,
            note=hb.note,
            alerted_state=prev.alerted_state if prev else "ok",
        )
        self._persist()

    def all(self) -> list[BotState]:
        return list(self._bots.values())

    def get(self, bot: str) -> BotState | None:
        return self._bots.get(bot)

    def set_alerted_state(self, bot: str, state: str) -> None:
        cur = self._bots.get(bot)
        if cur and cur.alerted_state != state:
            cur.alerted_state = state
            self._persist()

    def _persist(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            payload = {b.bot: b.model_dump() for b in self._bots.values()}
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(json.dumps(payload, indent=2))
            tmp.replace(self._path)  # atomic swap
        except OSError as exc:
            log.warning("could not persist state to %s: %s", self._path, exc)

    def _load(self) -> None:
        if not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text())
            self._bots = {k: BotState(**v) for k, v in raw.items()}
            log.info("loaded %d bot(s) from %s", len(self._bots), self._path)
        except (OSError, ValueError) as exc:
            log.warning("could not load state from %s: %s", self._path, exc)
