"""Gesture admission and posture execution, independent of dimOS and the robot SDK.

All methods run on one asyncio loop. There is no movement queue: an input is
accepted now or rejected with a reason. Arming permits one two-gesture exercise.
"""

from __future__ import annotations

import asyncio
import math
import time
from typing import Any, Callable

from dimos_esp32.gesture_packets import DEFAULT_ADDRESS, STALE_AFTER_S

EVENT_MAX_AGE_S = 1.0
MIN_COMMAND_GAP_S = 3.0
COMMAND_TIMEOUT_S = 5.0
STAND_SETTLE_S = 1.5


def finite_number(value: Any) -> bool:
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def acknowledgment_code(reply: Any) -> int:
    """The driver's response includes data.header.status.code, not a bare header."""
    try:
        code = reply["data"]["header"]["status"]["code"]
    except (KeyError, TypeError):
        raise ValueError("robot response has no acknowledgment code") from None
    if type(code) is not int:
        raise ValueError("robot acknowledgment code is not an integer")
    return code


class PostureControl:
    def __init__(
        self,
        driver: Any,
        emit: Callable[[dict[str, Any]], None],
        address: str = DEFAULT_ADDRESS,
        *,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
        stand_settle_s: float = STAND_SETTLE_S,
    ) -> None:
        self.driver = driver
        self.emit = emit
        self.address = address.upper()
        self.clock = clock
        self.monotonic = monotonic
        self.stand_settle_s = stand_settle_s
        self.armed = False
        self.armed_at = float("inf")
        self.remaining = 0
        self.busy = False
        self.last_event_ts = float("-inf")
        self.last_action_at = float("-inf")
        self.board: dict[str, Any] | None = None
        self.board_received_at = float("-inf")
        self.reason = "startup_disarmed"
        self.task: asyncio.Task[None] | None = None

    def snapshot(self, **extra: Any) -> dict[str, Any]:
        return {
            "board": self.address,
            "mode": self.driver.mode,
            "connected": self.driver.connected,
            "armed": self.armed,
            "busy": self.busy,
            "remaining": self.remaining,
            "reason": self.reason,
            "ts": self.clock(),
            **extra,
        }

    def report(self, **extra: Any) -> dict[str, Any]:
        status = self.snapshot(**extra)
        self.emit(status)
        return status

    def board_fresh(self) -> bool:
        if self.board is None or self.board.get("state") != "online":
            return False
        age = self.board.get("last_seen_age_s")
        return (
            finite_number(age)
            and 0 <= age <= STALE_AFTER_S
            and self.monotonic() - self.board_received_at <= 1.5
            and age + max(0, self.clock() - self.board["ts"]) <= STALE_AFTER_S
        )

    def receive_status(self, status: Any) -> None:
        if not isinstance(status, dict) or status.get("board") != self.address:
            return
        ts = status.get("ts")
        if not finite_number(ts) or not 0 <= self.clock() - ts <= EVENT_MAX_AGE_S:
            self.disarm("invalid_board_status")
            return
        previous = self.board
        self.board = status
        self.board_received_at = self.monotonic()
        if not self.board_fresh():
            self.disarm("board_" + str(status.get("state", "invalid")))
        elif previous and previous.get("posture") in (1, 2) and status.get("posture") == 0:
            self.disarm("board_reset")

    def arm(self) -> dict[str, Any]:
        if self.armed:
            return self.report(event="arm_rejected", detail="already_armed")
        if self.busy or not self.driver.connected or not self.board_fresh():
            return self.report(event="arm_rejected", detail="busy_or_connection_not_ready")
        self.armed = True
        self.armed_at = self.clock()
        self.remaining = 2
        self.reason = "human_ready"
        return self.report(event="armed")

    def disarm(self, reason: str = "operator") -> dict[str, Any]:
        changed = self.armed or self.reason != reason
        self.armed = False
        self.remaining = 0
        self.reason = reason
        return self.report(event="disarmed") if changed else self.snapshot()

    def tick(self) -> None:
        if not self.driver.connected:
            self.disarm("robot_disconnected")
        elif not self.board_fresh():
            self.disarm("board_stale_or_missing")

    def receive_gesture(self, event: Any) -> bool:
        if not isinstance(event, dict) or event.get("board") != self.address:
            self.report(event="gesture_rejected", detail="wrong_board_or_invalid_message")
            return False
        ts, count = event.get("ts"), event.get("count")
        if (
            event.get("gesture") not in ("SIT", "STAND")
            or type(count) is not int
            or not 0 <= count <= 255
            or not finite_number(ts)
            or not 0 <= self.clock() - ts <= EVENT_MAX_AGE_S
        ):
            self.report(event="gesture_rejected", detail="invalid_or_expired_event")
            return False
        if ts <= self.last_event_ts:
            self.report(event="gesture_rejected", detail="duplicate_or_out_of_order")
            return False
        self.last_event_ts = ts
        self.tick()
        reason = None
        if not self.armed or ts <= self.armed_at:
            reason = "disarmed_or_before_arm"
        elif self.busy:
            reason = "action_in_progress"
        elif self.monotonic() - self.last_action_at < MIN_COMMAND_GAP_S:
            reason = "minimum_command_gap"
        if reason:
            self.report(event="gesture_rejected", detail=reason, count=count)
            return False
        self.busy = True
        self.last_action_at = self.monotonic()
        self.report(event="gesture_accepted", gesture=event["gesture"], count=count)
        self.task = asyncio.create_task(self._act(event["gesture"], count))
        return True

    async def _act(self, gesture: str, count: int) -> None:
        try:
            commands = ("StandDown",) if gesture == "SIT" else ("StandUp", "BalanceStand")
            for index, command in enumerate(commands):
                if index:
                    await asyncio.sleep(self.stand_settle_s)
                self.report(event="command_requested", command=command, count=count)
                reply = await asyncio.wait_for(self.driver.sport(command), COMMAND_TIMEOUT_S)
                code = acknowledgment_code(reply)
                self.report(event="command_ack", command=command, code=code, count=count)
                if code != 0:
                    raise RuntimeError("robot rejected posture command")
            self.report(event="action_complete", gesture=gesture, count=count)
            if self.armed:
                self.remaining -= 1
                if self.remaining == 0:
                    self.disarm("test_pair_complete")
        except Exception as exc:
            self.disarm("command_failed")
            self.report(event="action_failed", error_type=type(exc).__name__, count=count)
        finally:
            self.busy = False
            self.report(event="idle")

    async def close(self) -> None:
        self.disarm("shutdown")
        try:
            if self.task is not None:
                await asyncio.wait_for(asyncio.shield(self.task), timeout=15)
        finally:
            await asyncio.wait_for(self.driver.disconnect(), timeout=5)
            self.report(event="stopped")
