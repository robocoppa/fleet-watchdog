"""FastAPI app: heartbeat receiver + background watchdog loop.

Endpoints:
    POST /beat     bots check in here (the only write path).
    GET  /status   the fleet table, for eyeballing in a browser or curl.
    GET  /healthz  liveness for the container itself.

The watchdog loop runs as a background task started on app startup, so the one
process both ingests heartbeats and fires alerts.
"""

from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .models import Heartbeat
from .notify import Notifier
from .registry import Registry
from .settings import load_settings
from .store import FleetStore
from .watchdog import Watchdog, evaluate

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("fleet_watchdog")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    store = FleetStore(settings.state_path)
    registry = Registry(settings.registry_path, settings.default_stale_after)
    notifier = Notifier(settings.token, settings.chat_id)
    watchdog = Watchdog(store, registry, notifier, settings.tick_seconds)

    app.state.store = store
    app.state.registry = registry
    app.state.notifier = notifier

    if not notifier.enabled:
        log.warning(
            "WATCHDOG_TOKEN / WATCHDOG_CHAT_ID not set — alerts will be logged, not sent."
        )
    log.info("registry=%s state=%s known bots=%s",
             settings.registry_path, settings.state_path, sorted(registry.known_bots()))

    task = asyncio.create_task(watchdog.run())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await notifier.aclose()


app = FastAPI(title="fleet-watchdog", lifespan=lifespan)


@app.post("/beat")
async def beat(hb: Heartbeat) -> dict:
    app.state.store.record(hb)
    return {"ok": True}


@app.get("/status")
async def status() -> JSONResponse:
    store: FleetStore = app.state.store
    registry: Registry = app.state.registry
    now = time.time()
    rows = []
    for bot in sorted(store.all(), key=lambda b: b.bot):
        policy = registry.policy_for(bot.bot)
        rows.append(
            {
                "bot": bot.bot,
                "host": bot.host,
                "state": evaluate(bot, policy, now),
                "age_s": round(now - bot.last_seen),
                "expected_up": policy.expected_up,
                "stale_after": policy.stale_after,
                "getme_ok": bot.getme_ok,
                "send_ok": bot.send_ok,
                "send_error": bot.send_error,
                "backend_ok": bot.backend_ok,
                "note": bot.note,
            }
        )
    return JSONResponse({"now": round(now), "bots": rows})


@app.get("/healthz")
async def healthz() -> dict:
    return {"ok": True}


def run() -> None:
    import uvicorn

    settings = load_settings()
    uvicorn.run(app, host=settings.host, port=settings.port)
