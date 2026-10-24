"""The previously working local Go2 posture protocol, without auto-posture lifecycle."""

from __future__ import annotations

import os
from pathlib import Path
import stat
from typing import Any


class LocalGo2Driver:
    mode = "robot"

    def __init__(self) -> None:
        self.connection: Any = None

    @property
    def connected(self) -> bool:
        c = self.connection
        return bool(
            c is not None
            and c.pc is not None
            and c.pc.connectionState == "connected"
            and c.datachannel.data_channel_opened
        )

    async def connect(self) -> None:
        from unitree_webrtc_connect.webrtc_driver import (
            UnitreeWebRTCConnection,
            WebRTCConnectionMethod,
        )

        # Only consume a task-owned, one-use memory-file copy. Never unlink the
        # canonical /root/go2-aes.key, or serialize its value as blueprint config.
        path = Path(os.environ["DIMOS_ESP32_GO2_KEY_FILE"])
        parent = path.parent
        if parent.parent != Path("/dev/shm") or not parent.name.startswith("dimos-go2-"):
            raise ValueError("expected a one-use key file in /dev/shm/dimos-go2-*")
        for target, mode in ((parent, 0o700), (path, 0o600)):
            info = target.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != mode:
                raise ValueError("one-use key ownership or permissions are invalid")
        key = path.read_text().strip()
        path.unlink()
        if len(key) != 32 or any(c not in "0123456789abcdefABCDEF" for c in key):
            raise ValueError("expected a 32-character hexadecimal robot key")
        self.connection = UnitreeWebRTCConnection(
            WebRTCConnectionMethod.LocalAP, aes_128_key=key
        )
        await self.connection.connect()

    async def sport(self, command: str) -> Any:
        from unitree_webrtc_connect.constants import RTC_TOPIC, SPORT_CMD

        if command not in ("StandDown", "StandUp", "BalanceStand"):
            raise ValueError("unsupported posture command")
        if not self.connected:
            raise ConnectionError("robot is not connected")
        return await self.connection.datachannel.pub_sub.publish_request_new(
            RTC_TOPIC["SPORT_MOD"], {"api_id": SPORT_CMD[command]}
        )

    async def disconnect(self) -> None:
        if self.connection is not None:
            await self.connection.disconnect()


class SimulatedGo2Driver:
    """Explicitly labeled dry run; no SDK import, key access or robot sockets."""

    mode = "simulation"

    def __init__(self) -> None:
        self.connected = False

    async def connect(self) -> None:
        self.connected = True

    async def sport(self, command: str) -> dict[str, Any]:
        return {"data": {"header": {"status": {"code": 0}}}}

    async def disconnect(self) -> None:
        self.connected = False
