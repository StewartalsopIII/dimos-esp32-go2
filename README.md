# dimos-esp32-go2

Two things we built for a Unitree Go2 Air while learning [dimOS](https://github.com/dimensionalOS/dimos), from
[AI Whisperers](https://aiwhisperers.org) in Buenos Aires. Walk through both and vote on which should be proposed to
dimOS first: <https://aiwhisperers.org/clips/dimos-voxel-house-a93e8b26/>

| Folder | What it is |
|---|---|
| `go2-leash-ios/` | **Follow mode with no Pi.** An iPhone app that talks to the Go2 directly over the dog's own Wi-Fi (WebRTC), listens to an ESP32 "leash" over Bluetooth, and with follow mode on finds a person in the dog's camera on the phone (Apple Vision, no cloud) and steers toward them. |
| `dimos_esp32/` | **An ESP32 as a dimOS input.** A dimOS module that turns the board's Bluetooth broadcasts into dimOS topics, and a second module that makes a Go2 lie down / stand up from those gestures. |
| `esp32/go2_leash/` | The ESP32 sketch both of them listen to (BOOT button, bare touch pins, optional ultrasonic sensor). |

## Status, honestly

- Tested on one Go2 Air and one HiLetgo ESP32 DevKitC (WROOM-32), October 2026.
- **The follow math has no tests yet**, and every change was tried on the real dog, which is the opposite of dimOS's
  "simulation before hardware" rule. Tests for `followCommand` are the next thing.
- Follow mode picks the biggest person in frame and stutters on arrival (stop line flips every 0.5 s).
- The dimOS side only does lie down and stand up.

## Safety

Clear floor, someone ready to pick the dog up, and start with it lying down. The app only moves the dog while it is
connected, armed and standing, the board was heard in the last second, and the button (or touch edge) is held.
Release, a silent board, a lost person box for 0.5 s, leaving the app or a disconnect all stop it. Speed caps:
forward 0.3 m/s, turn 0.6 rad/s.

## The ESP32 board

```
arduino-cli compile --fqbn esp32:esp32:esp32 esp32/go2_leash
arduino-cli upload --fqbn esp32:esp32:esp32 -p <port> esp32/go2_leash
```

It only advertises over Bluetooth (no pairing), manufacturer data `FF FF <state> <seq> <posture> <cm> <count>`;
the sketch header documents the modes. `esp32/go2_leash/tools/blescan.swift` listens from a Mac.

## The iPhone app

Needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an iPhone (iOS 17+). Set your Apple team in
`go2-leash-ios/project.yml`, then `xcodegen generate` and run from Xcode. Put the dog's 32-hex-character per-device
key in a file named `robot.key` and copy it into the app's Documents folder, for example
`xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier org.aiwhisperers.Go2Leash --source robot.key --destination Documents/robot.key`.
On launch the app moves it into the iOS keychain and deletes the file. Then join the dog's own Wi-Fi, connect, pick
your board, arm.

## The dimOS modules

```
pip install -e .            # into the same environment as dimOS (tested with dimos[unitree]==0.0.14)
export DIMOS_ESP32_GESTURE_ADDRESS=<your board's BLE address>
dimos run dimos-esp32.gestures       # topics only, no robot
```

`gesture-go2` also drives the dog through `unitree_webrtc_connect` and reads the robot key from a one-use file under
`/dev/shm/dimos-go2-*` (`DIMOS_ESP32_GO2_KEY_FILE`); see `dimos_esp32/go2_posture_driver.py`.

## Keys and privacy

No keys are in this repository. The robot key is per device; never commit it. Everything here runs on the dog's own
Wi-Fi with no internet and no cloud.

## License

MIT, see `LICENSE`. Third-party code and credits: `THIRD_PARTY_NOTICES.md`.
