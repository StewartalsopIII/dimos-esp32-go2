"""Decode the existing go2-leash BLE payload without radio or dimOS imports.

Bleak removes the two-byte manufacturer id (0xffff); the remaining bytes are
state, sequence, posture, distance_cm, and gesture counter. These are sensor
events, not authorization to move a robot.
"""

from __future__ import annotations

from dataclasses import dataclass

MANUFACTURER_ID = 0xFFFF
# Your board's BLE address (the sketch prints its MAC on serial; BLE = MAC + 2). Override with DIMOS_ESP32_GESTURE_ADDRESS.
DEFAULT_ADDRESS = "00:00:00:00:00:00"
STALE_AFTER_S = 2.0


@dataclass(frozen=True)
class GesturePacket:
    state: int
    sequence: int
    posture: int
    distance_cm: int
    count: int

    @property
    def gesture(self) -> str | None:
        return {1: "SIT", 2: "STAND"}.get(self.posture)


def decode_packet(payload: bytes) -> GesturePacket:
    if len(payload) != 5:
        raise ValueError(f"expected 5 manufacturer bytes, received {len(payload)}")
    packet = GesturePacket(*payload)
    if packet.state not in (0, 1) or packet.posture not in (0, 1, 2):
        raise ValueError("invalid state or posture in manufacturer data")
    return packet


class GestureTracker:
    """Baseline startup/reconnect; deduplicate ads; expose gaps and resets."""

    def __init__(self, stale_after_s: float = STALE_AFTER_S) -> None:
        self.stale_after_s = stale_after_s
        self.last_seen: float | None = None
        self.packet: GesturePacket | None = None

    def observe(self, packet: GesturePacket, now: float) -> tuple[bool, str | None]:
        previous = self.packet
        baseline = previous is None or self.is_stale(now) or packet.posture == 0
        self.last_seen = now
        if baseline:
            self.packet = packet
            return False, None
        assert previous is not None
        delta = (packet.count - previous.count) % 256
        if delta == 0:
            if packet.posture != previous.posture:
                return False, "posture changed without a new gesture counter"
            self.packet = packet
            return False, None
        if delta >= 128:
            # Do not turn an old/out-of-order advertisement into a new event.
            return False, "counter moved backwards; waiting for a fresh counter or baseline"
        self.packet = packet
        warning = f"missed {delta - 1} gesture counter(s)" if delta > 1 else None
        return True, warning

    def is_stale(self, now: float) -> bool:
        return self.last_seen is not None and now - self.last_seen > self.stale_after_s

    def state(self, now: float) -> str:
        if self.last_seen is None:
            return "waiting"
        return "stale" if self.is_stale(now) else "online"
