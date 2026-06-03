"""Unit tests for the watchdog's pure health-evaluation logic.

evaluate() is the whole decision surface — staleness vs. send/token/backend
failures, and the expected_up gate that keeps roaming laptops quiet. Testing it
directly means no timers, no Telegram, no FastAPI.
"""

from __future__ import annotations

from fleet_watchdog.models import BotState
from fleet_watchdog.registry import BotPolicy
from fleet_watchdog.watchdog import evaluate

NOW = 1_000_000.0


def _bot(**kw) -> BotState:
    base = dict(bot="b", host="h", last_seen=NOW, getme_ok=True, send_ok=True, backend_ok=True)
    base.update(kw)
    return BotState(**base)


def _policy(**kw) -> BotPolicy:
    base = dict(
        expected_up=True,
        stale_after=300,
        alert_on_send_fail=True,
        alert_on_token_fail=True,
        alert_on_backend_fail=False,
    )
    base.update(kw)
    return BotPolicy(**base)


def test_fresh_and_healthy_is_ok():
    assert evaluate(_bot(), _policy(), NOW) == "ok"


def test_stale_expected_up_is_stale():
    bot = _bot(last_seen=NOW - 400)
    assert evaluate(bot, _policy(stale_after=300), NOW) == "stale"


def test_stale_transient_stays_ok():
    # A roaming laptop that's asleep is not an incident.
    bot = _bot(last_seen=NOW - 9999)
    assert evaluate(bot, _policy(expected_up=False), NOW) == "ok"


def test_send_fail_while_fresh():
    # The headline case: process up and beating, but it can't post to the chat.
    bot = _bot(send_ok=False, send_error="bot was blocked by the user")
    assert evaluate(bot, _policy(), NOW) == "send_fail"


def test_send_fail_suppressed_when_opted_out():
    bot = _bot(send_ok=False)
    assert evaluate(bot, _policy(alert_on_send_fail=False), NOW) == "ok"


def test_token_fail_takes_priority_over_send():
    # If getMe failed we can't trust the send result; report the token problem.
    bot = _bot(getme_ok=False, send_ok=False)
    assert evaluate(bot, _policy(), NOW) == "token_fail"


def test_staleness_beats_send_fail():
    # A stale bot can't have a trustworthy fresh send result — staleness wins.
    bot = _bot(last_seen=NOW - 400, send_ok=False)
    assert evaluate(bot, _policy(stale_after=300), NOW) == "stale"


def test_backend_fail_only_when_opted_in():
    bot = _bot(backend_ok=False)
    assert evaluate(bot, _policy(alert_on_backend_fail=False), NOW) == "ok"
    assert evaluate(bot, _policy(alert_on_backend_fail=True), NOW) == "backend_fail"


def test_send_fail_alerts_even_on_transient_while_awake():
    # expected_up=False suppresses STALE, but a beating transient that can't
    # send still surfaces if you opted into send alerts.
    bot = _bot(send_ok=False, send_error="chat not found")
    assert evaluate(bot, _policy(expected_up=False), NOW) == "send_fail"
