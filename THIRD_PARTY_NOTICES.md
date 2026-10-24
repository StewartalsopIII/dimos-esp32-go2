# Third-party notices

## unitree_webrtc_connect

`go2-leash-ios/Sources/Go2Protocol.swift` and `Go2Connection.swift` are a Swift port of the LocalAP connection flow in
[legion1581/unitree_webrtc_connect](https://github.com/legion1581/unitree_webrtc_connect) 2.2.0 (`unitree_auth.py`,
`encryption.py`, `msgs/validation.py`), including its static AES-GCM key for older firmware. The Python driver in
`dimos_esp32/go2_posture_driver.py` imports that library at runtime. Its license:

```
MIT License

Copyright (c) 2025 Konstantin Severov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.```

## WebRTC for iOS

The iOS app depends on [stasel/WebRTC](https://github.com/stasel/WebRTC) 125.0.0 (Swift Package), under its own license.
