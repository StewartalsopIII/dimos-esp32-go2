"""dimOS blueprints: an ESP32 over Bluetooth as a dimOS input.

    dimos run dimos-esp32.gestures     # ESP32 BLE -> esp32_gestures, esp32_status (no robot)
    dimos run dimos-esp32.gesture-go2  # the same gestures make a Go2 lie down / stand up
"""

from __future__ import annotations

from dimos.core.coordination.blueprints import autoconnect

from dimos_esp32.gesture_bridge import GestureBridge
from dimos_esp32.go2_posture_module import Go2PostureControl

gesture_blueprint = autoconnect(GestureBridge.blueprint())
gesture_go2_blueprint = autoconnect(GestureBridge.blueprint(), Go2PostureControl.blueprint())
