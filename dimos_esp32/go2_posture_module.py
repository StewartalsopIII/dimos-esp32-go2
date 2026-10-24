"""dimOS consumer for the two-gesture Go2 posture exercise; starts disarmed."""

from __future__ import annotations

import asyncio
import json
import os
import threading
import time
from typing import Any

from dimos.core.core import rpc
from dimos.core.module import Module
from dimos.core.stream import In, Out
from dimos.msgs.std_msgs.String import String
from dimos.utils.logging_config import setup_logger

from dimos_esp32.gesture_packets import DEFAULT_ADDRESS
from dimos_esp32.go2_posture_driver import LocalGo2Driver, SimulatedGo2Driver
from dimos_esp32.posture_control import PostureControl

logger = setup_logger()


class Go2PostureControl(Module):
    esp32_gestures: In[String]
    esp32_status: In[String]
    go2_control_status: Out[String]

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._control_loop: asyncio.AbstractEventLoop | None = None
        self._control_thread: threading.Thread | None = None
        self._control: PostureControl | None = None
        self._connect_task: asyncio.Task[None] | None = None
        self._shutdown = threading.Event()
        self._unsubscribers: list[Any] = []

    @rpc
    def start(self) -> None:
        super().start()
        self._shutdown.clear()
        self._unsubscribers = [
            self.esp32_gestures.subscribe(lambda m: self._receive("receive_gesture", m)),
            self.esp32_status.subscribe(lambda m: self._receive("receive_status", m)),
        ]
        self._control_thread = threading.Thread(target=self._run, name="go2-posture", daemon=True)
        self._control_thread.start()

    def _emit(self, status: dict[str, Any]) -> None:
        status = {
            "ts": time.time(),
            "mode": "simulation" if os.environ.get("DIMOS_ESP32_GO2_SIMULATE") == "1" else "robot",
            **status,
        }
        self.go2_control_status.publish(String(data=json.dumps(status)))
        if status.get("event") != "heartbeat":
            logger.info("[go2-control] " + json.dumps(status))

    def _receive(self, method: str, message: String) -> None:
        try:
            data = json.loads(message.data)
        except (ValueError, TypeError):
            self._emit({"event": "input_rejected", "reason": "invalid_json"})
            return
        loop, control = self._control_loop, self._control
        if loop is None or control is None or not loop.is_running():
            self._emit({"event": "input_rejected", "reason": "controller_not_started"})
            return
        loop.call_soon_threadsafe(getattr(control, method), data)

    def _run(self) -> None:
        try:
            asyncio.run(self._main())
        except Exception as exc:
            self._emit({"event": "controller_error", "armed": False, "error_type": type(exc).__name__})

    async def _main(self) -> None:
        self._control_loop = asyncio.get_running_loop()
        simulated = os.environ.get("DIMOS_ESP32_GO2_SIMULATE") == "1"
        driver = SimulatedGo2Driver() if simulated else LocalGo2Driver()
        control = self._control = PostureControl(
            driver,
            self._emit,
            os.environ.get("DIMOS_ESP32_GESTURE_ADDRESS", DEFAULT_ADDRESS),
        )
        control.report(event="connecting")
        try:
            self._connect_task = asyncio.create_task(driver.connect())
            await asyncio.wait_for(self._connect_task, timeout=40)
            control.report(event="connected_disarmed")
            while not self._shutdown.is_set():
                control.tick()
                control.report(event="heartbeat")
                await asyncio.sleep(0.25)
        except asyncio.CancelledError:
            if not self._shutdown.is_set():
                raise
        finally:
            await control.close()

    async def _invoke(self, method: str) -> dict[str, Any]:
        assert self._control is not None
        return getattr(self._control, method)()

    def _rpc_control(self, method: str) -> dict[str, Any]:
        loop = self._control_loop
        if loop is None or self._control is None or not loop.is_running():
            return {"armed": False, "reason": "controller_not_running"}
        return asyncio.run_coroutine_threadsafe(self._invoke(method), loop).result(timeout=3)

    @rpc
    def arm(self) -> dict[str, Any]:
        """After human readiness only: accept two fresh gestures, then disarm."""
        return self._rpc_control("arm")

    @rpc
    def disarm(self) -> dict[str, Any]:
        """Prevent new actions; allow an already-requested stand to finish balancing."""
        return self._rpc_control("disarm")

    @rpc
    def control_status(self) -> dict[str, Any]:
        return self._rpc_control("snapshot")

    @rpc
    def stop(self) -> None:
        for unsubscribe in self._unsubscribers:
            unsubscribe()
        self._unsubscribers = []
        self._shutdown.set()
        loop, connect_task = self._control_loop, self._connect_task
        if loop is not None and loop.is_running() and connect_task is not None:
            loop.call_soon_threadsafe(connect_task.cancel)
        if self._control_thread is not None:
            self._control_thread.join(timeout=25)
            if self._control_thread.is_alive():
                logger.error("[go2-control] controller did not stop within 25 seconds")
        super().stop()
