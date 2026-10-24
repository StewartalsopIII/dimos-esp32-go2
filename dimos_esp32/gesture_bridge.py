"""One ESP32 sensor's BLE advertisements -> dimOS events and freshness.

Only listens to advertisements. Does not connect to the board, change Wi-Fi,
load a robot connection, or issue robot commands.
"""

from __future__ import annotations

import asyncio
import json
import os
import threading
import time
from typing import Any

from dimos.core.core import rpc
from dimos.core.module import Module
from dimos.core.stream import Out
from dimos.msgs.std_msgs.String import String
from dimos.utils.logging_config import setup_logger

from dimos_esp32.gesture_packets import DEFAULT_ADDRESS, MANUFACTURER_ID, GestureTracker, decode_packet

logger = setup_logger()


class GestureBridge(Module):
    esp32_gestures: Out[String]
    esp32_status: Out[String]

    def __init__(self, address: str | None = None, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.address = (address or os.environ.get("DIMOS_ESP32_GESTURE_ADDRESS", DEFAULT_ADDRESS)).upper()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._tracker = GestureTracker()
        self._last_warning: str | None = None

    @rpc
    def start(self) -> None:
        super().start()
        self._stop.clear()
        self._tracker = GestureTracker()
        self._thread = threading.Thread(target=self._run, name="esp32-gestures", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        try:
            asyncio.run(self._listen())
        except Exception as exc:
            logger.error(f"[gestures] Bluetooth receiver failed: {type(exc).__name__}: {exc}")
            self._publish_status("error", error=f"{type(exc).__name__}: {exc}")

    async def _listen(self) -> None:
        from bleak import BleakScanner

        logger.info(f"[gestures] listening for {self.address}; sensor events only")
        scanner = BleakScanner(detection_callback=self._on_receive)
        self._publish_status("waiting")
        try:
            await asyncio.wait_for(scanner.start(), timeout=15)
            last_state: str | None = None
            while not self._stop.is_set():
                state = self._tracker.state(time.monotonic())
                if state != last_state:
                    logger.info(f"[gestures] {self.address} {state}")
                    last_state = state
                self._publish_status(state)
                await asyncio.sleep(0.5)
        finally:
            await asyncio.wait_for(scanner.stop(), timeout=5)

    def _on_receive(self, device: Any, advertisement: Any) -> None:
        if device.address.upper() != self.address:
            return
        payload = advertisement.manufacturer_data.get(MANUFACTURER_ID)
        if payload is None:
            return  # A scan response without manufacturer data is normal.
        try:
            packet = decode_packet(payload)
        except ValueError as exc:
            self._warn(str(exc))
            return
        changed, warning = self._tracker.observe(packet, time.monotonic())
        self._warn(warning)
        if not changed:
            return
        event = {
            "board": self.address,
            "gesture": packet.gesture,
            "distance_cm": packet.distance_cm,
            "count": packet.count,
            "sequence": packet.sequence,
            "ts": time.time(),
        }
        self.esp32_gestures.publish(String(data=json.dumps(event)))
        logger.info(f"[gestures] {packet.gesture} count={packet.count} cm={packet.distance_cm}")

    def _warn(self, warning: str | None) -> None:
        if warning is not None and warning != self._last_warning:
            logger.warning(f"[gestures] {self.address}: {warning}")
        self._last_warning = warning

    def _publish_status(self, state: str, **extra: Any) -> None:
        seen = self._tracker.last_seen
        packet = self._tracker.packet
        status = {
            "board": self.address,
            "state": state,
            "last_seen_age_s": None if seen is None else round(time.monotonic() - seen, 3),
            "posture": None if packet is None else packet.posture,
            "count": None if packet is None else packet.count,
            "ts": time.time(),
            **extra,
        }
        self.esp32_status.publish(String(data=json.dumps(status)))

    @rpc
    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=10)
            if self._thread.is_alive():
                logger.warning("[gestures] Bluetooth receiver did not stop within 10 seconds")
        self._publish_status("stopped")
        super().stop()
