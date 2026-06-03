"""Wire and state shapes for the watchdog.

A *heartbeat* is what each bot POSTs to the receiver every few minutes. It
carries not just "I am alive" but the result of the bot's own self-checks
against Telegram — crucially ``send_ok``, which is the result of a real
sendMessage-then-delete probe against the bot's actual target chat. That is
the signal that catches "process is up but it can no longer talk to the chat"
(blocked, kicked, chat migrated, rate-limited).
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class Heartbeat(BaseModel):
    """One check-in from a single bot on a single laptop."""

    bot: str = Field(..., description="Stable bot id, e.g. 'hermes-claudette'. Matches registry.")
    host: str = Field(..., description="Machine the bot runs on, for the alert text.")
    # The bot's own self-checks, performed laptop-side just before POSTing:
    getme_ok: bool = Field(True, description="getMe succeeded (token valid, Telegram reachable).")
    send_ok: bool = Field(
        True,
        description="A real sendMessage to the bot's target chat succeeded "
        "(then deleted). False means the bot is running but cannot post "
        "to its chat.",
    )
    send_error: str | None = Field(
        None, description="Telegram error description when send_ok is false (e.g. 'bot was blocked')."
    )
    backend_ok: bool = Field(
        True, description="Optional: model backend (Ollama/Audrey) reachable from the bot."
    )
    note: str | None = Field(None, description="Free-form, shown in /status and alerts.")


class BotState(BaseModel):
    """Server-side last-known state for one bot, persisted across restarts."""

    bot: str
    host: str
    last_seen: float  # unix epoch seconds of the most recent heartbeat
    getme_ok: bool = True
    send_ok: bool = True
    send_error: str | None = None
    backend_ok: bool = True
    note: str | None = None
    # Edge-trigger memory so we alert once per transition, not every tick.
    # One of: "ok", "stale", "send_fail", "token_fail", "backend_fail".
    alerted_state: str = "ok"
