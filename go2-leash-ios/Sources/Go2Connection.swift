// Go2 connection over the robot's own Wi-Fi AP (LocalAP flow of
// unitree_webrtc_connect 2.2.0): signals, validates the data channel, sends the
// protocol heartbeat, reads low-state for battery and sport-mode state for body
// height. Sport requests: posture (lie down / stand up) and, in walk mode only,
// hold-to-walk straight ahead at a fixed slow speed (Move) with explicit stops. Arming is
// explicit and lasts until Disarm, a disconnect, a bad ack or the selected board
// going silent (Stewart, 2026-10-22); 3 s gap between posture commands.
// Connect and disconnect send no command. Follow mode: while the board is held, steer toward
// the largest person in the dog's own video (PersonTracker); a lost person stops like a release.

import Foundation
import WebRTC

@MainActor
final class Go2Connection: NSObject, ObservableObject {
    static let robotIP = "192.168.12.1"

    @Published var phase = "idle"
    @Published var ice = "-"
    @Published var peer = "-"
    @Published var channel = "-"
    @Published var validated = false
    @Published var lastHeartbeatAck: Date?
    @Published var battery: Int?
    @Published var messages = 0
    @Published var log: [String] = []
    @Published var armed = false
    @Published var busy = false
    @Published var lastAck = "-"
    @Published var bodyHeight: Double?
    @Published var bodyHeightAt = Date.distantPast

    @Published var walkMode = false
    @Published var followMode = false
    @Published var moving = false
    @Published var videoTrack: RTCVideoTrack?

    /// A person box older than this stops a follow walk.
    static let personFreshness: TimeInterval = 0.5
    /// Follow distance from where the feet sit in the frame (box bottom, 0 = bottom edge).
    /// The low camera sees mostly legs, so box height is ~1 at every distance (10-23 screenshots);
    /// feet climb toward the horizon (~0.27) as the person moves away. Below this = close enough.
    static let followNearFeet = 0.08
    static let followMaxTurn = 0.6          // rad/s
    /// No creeping: tiny Move speeds made the dog rock in place ("humping", 10-23 run 1).
    static let followMinForward = 0.15
    private var followLoggedAt = Date.distantPast

    static let commandGap: TimeInterval = 3
    /// Forward speed while BOOT is held (m/s). Deliberately slow for the first trials.
    static let walkSpeed = 0.3
    /// Backward is blind (no rear camera view for the operator), so slower.
    static let backSpeed = 0.2
    @Published private(set) var walkDir = 0
    /// The held signal must be newer than this or the dog is stopped.
    /// 1 s (was 0.5 s, too tight for BLE: 10-22 walks stopped on "board silent" mid-hold).
    /// Worst case the dog walks ~1 s (~30 cm) after the board dies.
    static let heldFreshness: TimeInterval = 1.0
    var onWalkStart: (() -> Void)?
    var walkStopDetail: (() -> String)?
    private var moveId = 0
    private var stopBurst = 0
    /// Above this the dog counts as standing for the board's toggle (measure live; see the app row).
    static let standingHeight = 0.2
    static let stateStaleAfter: TimeInterval = 1
    private static let sportTopic = "rt/api/sport/request"
    private static let api = ["StandDown": 1005, "StandUp": 1004, "BalanceStand": 1002]
    private var lastCommandAt = Date.distantPast
    private var pending: [Int: (String, CheckedContinuation<Int?, Never>)] = [:]

    private let factory: RTCPeerConnectionFactory
    private var pc: RTCPeerConnection?
    private var dc: RTCDataChannel?
    private var challenge = ""
    private var heartbeat: Timer?
    private var gatheringDone: CheckedContinuation<Void, Never>?
    private var lastBatteryUpdate = Date.distantPast

    override init() {
        RTCInitializeSSL()
        // No audio I/O at all: the audio m-line is receive-only and the
        // phone never opens the microphone or speaker for this status client.
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        factory = RTCPeerConnectionFactory()
        super.init()
    }

    func note(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp) \(line)")
        if log.count > 80 { log.removeFirst(log.count - 80) }
        print("[go2] \(line)")
        Self.appendToFile("\(Date().ISO8601Format()) \(line)\n")
    }

    /// Every log line also goes to Documents/go2-log.txt, pulled later over home Wi-Fi with
    /// `devicectl device copy from --domain-type appDataContainer` (the phone is on the dog's
    /// Wi-Fi during a run, so the Mac cannot stream the console).
    static let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("go2-log.txt")

    private static func appendToFile(_ text: String) {
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    var connected: Bool { pc != nil && validated }

    func connect() {
        guard pc == nil else { return }
        guard let keyHex = KeyStore.load() else {
            phase = "no robot key in keychain"
            note(phase)
            return
        }
        validated = false
        battery = nil
        messages = 0
        lastHeartbeatAck = nil
        Task { await self.run(keyHex: keyHex) }
    }

    // MARK: arming + posture

    func arm() {
        guard connected, !busy else { return }
        armed = true
        note("ARMED until Disarm, board loss or disconnect")
    }

    func disarm(_ why: String) {
        guard armed else { return }
        armed = false
        note("disarmed (\(why))")
    }

    /// Standing / lying from the dog's own fresh sport-mode state, or nil if unknown.
    var standing: Bool? {
        guard let h = bodyHeight, Date().timeIntervalSince(bodyHeightAt) <= Self.stateStaleAfter else { return nil }
        return h >= Self.standingHeight
    }

    func lieDown() { Task { await self.posture(["StandDown"]) } }
    func standUp() { Task { await self.posture(["StandUp", "BalanceStand"]) } }

    // MARK: hold-to-walk

    /// Called at 10 Hz. Moves only while every condition holds; any failure sends stops.
    /// dir: 1 = forward, -1 = backward, 0 = released (from the board's state byte).
    func walkTick(dir: Int, heldAge: TimeInterval, person: FollowTarget? = nil) {
        var why: String?
        var follow: (Double, Double)?
        if !walkMode && !followMode { why = "walk mode off" }
        else if !connected { why = "not connected" }
        else if !armed { why = "not armed" }
        else if busy { why = "busy" }
        else if standing != true { why = "dog not standing" }
        else if heldAge > Self.heldFreshness { why = "board silent" }
        else if dir == 0 { why = "released" }
        else if followMode {
            if let person, Date().timeIntervalSince(person.at) <= Self.personFreshness {
                follow = Self.followCommand(person)
            } else { why = "person lost" }
        }
        if why == nil {
            let speed = dir > 0 ? Self.walkSpeed : -Self.backSpeed
            if !moving { note(follow == nil ? "walk start (\(speed) m/s)" : "follow start"); onWalkStart?() }
            else if follow == nil, dir != walkDir { note("walk direction -> \(speed) m/s") }
            walkDir = follow == nil ? dir : 1
            moving = true
            stopBurst = 5
            if let (x, z) = follow {
                sendMove(x, turn: z)
                if Date().timeIntervalSince(followLoggedAt) >= 0.5, let p = person {
                    followLoggedAt = Date()
                    note(String(format: "follow cx %.2f feet %.2f → fwd %.2f turn %+.2f", p.centerX, p.feet, x, z))
                }
            } else { sendMove(speed) }
        } else if moving || stopBurst > 0 {
            if moving { note("walk stop: \(why!)" + (walkStopDetail.map { " · " + $0() } ?? "")) }
            moving = false
            sendMove(0)
            stopBurst -= 1
            if stopBurst == 0 { sendStopMove() }
        }
    }

    private func sendMove(_ x: Double, turn z: Double = 0) {
        moveId += 1
        send(["type": "req", "topic": Self.sportTopic, "data": [
            "header": ["identity": ["id": moveId, "api_id": 1008]],
            "parameter": "{\"x\": \(x), \"y\": 0, \"z\": \(z)}",
        ]])
    }

    /// (forward m/s, turn rad/s; positive turn = left) toward a person box. Turns to center
    /// the person, walks only while they are roughly ahead and still small in the frame.
    static func followCommand(_ t: FollowTarget) -> (Double, Double) {
        let offset = t.centerX - 0.5                     // + = person right of center
        let turn = abs(offset) < 0.12 ? 0 : max(-followMaxTurn, min(followMaxTurn, -1.6 * offset))
        var forward = 0.0
        if t.feet > followNearFeet, abs(offset) < 0.3 {
            forward = max(followMinForward, walkSpeed * min(1, (t.feet - followNearFeet) / 0.12))
        }
        return ((forward * 100).rounded() / 100, (turn * 100).rounded() / 100)
    }

    /// Ask the dog to start (or stop) sending its front-camera video.
    func setVideo(_ on: Bool) {
        send(["type": "vid", "topic": "", "data": on ? "on" : "off"])
        note("video \(on ? "on" : "off") requested")
    }

    private func sendStopMove() {
        moveId += 1
        send(["type": "req", "topic": Self.sportTopic, "data": [
            "header": ["identity": ["id": moveId, "api_id": 1003]], "parameter": "",
        ]])
    }

    /// A board press: do the opposite of the dog's real posture.
    func toggle(from source: String) {
        guard let standing else { return note("\(source) ignored: dog posture unknown (no fresh state)") }
        note("\(source): dog \(standing ? "standing" : "lying") (\(String(format: "%.2f", bodyHeight ?? 0)) m)")
        standing ? lieDown() : standUp()
    }

    private func posture(_ steps: [String]) async {
        guard connected else { return note("rejected: not connected") }
        guard armed else { return note("rejected: not armed") }
        guard !busy else { return note("rejected: busy") }
        guard Date().timeIntervalSince(lastCommandAt) >= Self.commandGap else {
            return note("rejected: within \(Int(Self.commandGap)) s of last command")
        }
        busy = true
        lastCommandAt = Date()
        defer { busy = false }
        for (i, step) in steps.enumerated() {
            if i > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            guard connected else { return note("aborted \(step): disconnected") }
            let code = await request(step)
            lastAck = "\(step) → \(code.map(String.init) ?? "no ack")"
            note("\(step) ack \(code.map(String.init) ?? "none (timeout)")")
            if code != 0 {
                disarm("bad ack")
                return
            }
        }
    }

    private func request(_ command: String) async -> Int? {
        let id = Int(Date().timeIntervalSince1970 * 1000) % 2147483648 + Int.random(in: 0...1000)
        let body: [String: Any] = ["header": ["identity": ["id": id, "api_id": Self.api[command]!]], "parameter": ""]
        note("sent \(command)")
        return await withCheckedContinuation { cont in
            pending[id] = (command, cont)
            send(["type": "req", "topic": Self.sportTopic, "data": body])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if let (_, c) = self.pending.removeValue(forKey: id) { c.resume(returning: nil) }
            }
        }
    }

    private func resolve(_ msg: [String: Any]) {
        guard let data = msg["data"] as? [String: Any],
              let header = data["header"] as? [String: Any],
              let identity = header["identity"] as? [String: Any],
              let id = identity["id"] as? Int,
              let (_, cont) = pending.removeValue(forKey: id)
        else { return }
        let code = (header["status"] as? [String: Any])?["code"] as? Int
        cont.resume(returning: code ?? -1)
    }

    func disconnect(_ why: String = "operator") {
        if moving { sendMove(0); sendStopMove(); moving = false; note("walk stop: disconnect") }
        disarm("disconnect")
        for (_, (_, c)) in pending { c.resume(returning: nil) }
        pending.removeAll()
        heartbeat?.invalidate()
        heartbeat = nil
        dc?.close()
        pc?.close()
        dc = nil
        pc = nil
        videoTrack = nil
        validated = false
        phase = "disconnected (\(why))"
        note(phase)
    }

    private func run(keyHex: String) async {
        let config = RTCConfiguration()
        config.iceServers = []                       // local only: no STUN/TURN
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.candidateNetworkPolicy = .lowCost     // skip cellular interfaces
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            fail("could not create peer connection")
            return
        }
        self.pc = pc
        dc = pc.dataChannel(forLabel: "data", configuration: RTCDataChannelConfiguration())
        dc?.delegate = self
        let video = RTCRtpTransceiverInit()
        video.direction = .recvOnly
        pc.addTransceiver(of: .video, init: video)
        // No audio m-line. Python offers sendrecv audio, but on iOS any
        // negotiated audio (even recvonly) starts the audio unit, which asks
        // for the microphone and aborts (TCC). Status needs only the data channel.

        do {
            phase = "creating offer"
            let offer = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(offer)
            await waitForGathering(timeout: 3)
            guard let local = pc.localDescription else { throw Go2ProtocolError.badAnswer }

            phase = "signaling \(Self.robotIP):9991"
            note(phase)
            let answer = try await signal(offerSDP: local.sdp, keyHex: keyHex)
            if answer == "reject" {
                fail("robot busy: another client (e.g. the Unitree app or the Pi) is connected")
                return
            }
            try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
            videoTrack = pc.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack
            note(videoTrack == nil ? "no video track in answer" : "video track ready")
            phase = "connecting (ICE/DTLS)"
            note("answer accepted; waiting for data channel + validation")
            try await Task.sleep(for: .seconds(15))
            if self.pc === pc && !validated { fail("data channel not validated within 15 s") }
        } catch {
            fail("\(error)")
        }
    }

    private func fail(_ why: String) {
        note("FAILED: \(why)")
        disconnect("failed")
        phase = "failed: \(why)"
    }

    private func waitForGathering(timeout: Double) async {
        if pc?.iceGatheringState == .complete { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gatheringDone = c
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.finishGathering()
            }
        }
    }

    private func finishGathering() {
        gatheringDone?.resume()
        gatheringDone = nil
    }

    // MARK: LAN signaling (con_notify → con_ing_<path>)

    private func post(_ path: String, body: String?, contentType: String?) async throws -> String {
        var req = URLRequest(url: URL(string: "http://\(Self.robotIP):9991/\(path)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body.map { Data($0.utf8) } ?? Data()
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }

    private func signal(offerSDP: String, keyHex: String) async throws -> String {
        let notify = try await post("con_notify", body: nil, contentType: nil)
        guard let decoded = Data(base64Encoded: notify.trimmingCharacters(in: .whitespacesAndNewlines)),
              let json = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              var data1 = json["data1"] as? String
        else { throw Go2ProtocolError.badData1 }
        let data2 = json["data2"] as? Int ?? 1
        note("con_notify ok (data2=\(data2))")
        if data2 == 2 {
            data1 = try Go2Protocol.decryptData1(data1, key: Go2Protocol.legacyGCMKey)
        } else if data2 == 3 {
            data1 = try Go2Protocol.decryptData1(data1, key: try Go2Protocol.keyBytes(hex: keyHex))
        }
        let (publicKeyB64, path) = try Go2Protocol.parseData1(data1)
        let sessionKey = Go2Protocol.newSessionKey()
        let offer: [String: String] = ["id": "", "sdp": offerSDP, "type": "offer", "token": ""]
        let offerJSON = String(data: try JSONSerialization.data(withJSONObject: offer), encoding: .utf8)!
        let body: [String: String] = [
            "data1": try Go2Protocol.aesEncrypt(offerJSON, key: sessionKey),
            "data2": try Go2Protocol.rsaEncrypt(sessionKey, key: try Go2Protocol.publicKey(b64: publicKeyB64)),
        ]
        let bodyJSON = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        let reply = try await post("con_ing_\(path)", body: bodyJSON, contentType: "application/x-www-form-urlencoded")
        let answerText = try Go2Protocol.aesDecrypt(reply, key: sessionKey)
        guard let answer = try JSONSerialization.jsonObject(with: Data(answerText.utf8)) as? [String: Any],
              let sdp = answer["sdp"] as? String
        else { throw Go2ProtocolError.badAnswer }
        note("SDP answer received")
        return sdp
    }

    // MARK: data channel protocol (validation, heartbeat, low-state)

    private func send(_ message: [String: Any]) {
        guard let dc, dc.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        dc.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func onValidated() {
        validated = true
        phase = "connected + validated"
        note("data channel validated")
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.sendHeartbeat() }
        }
        send(["type": "subscribe", "topic": "rt/lf/lowstate"])
        send(["type": "subscribe", "topic": "rt/lf/sportmodestate"])
        setVideo(true)
    }

    private func sendHeartbeat() {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        send(["type": "heartbeat", "topic": "", "data": ["timeInStr": f.string(from: now), "timeInNum": Int(now.timeIntervalSince1970)]])
    }

    fileprivate func handle(_ buffer: RTCDataBuffer) {
        messages += 1
        guard let msg = Self.decode(buffer), let type = msg["type"] as? String else { return }
        switch type {
        case "validation":
            if (msg["data"] as? String) == "Validation Ok." {
                onValidated()
            } else if let c = msg["data"] as? String {
                challenge = c
                send(["type": "validation", "topic": "", "data": Go2Protocol.validationReply(c)])
                note("validation challenge answered")
            }
        case "err":
            if (msg["info"] as? String) == "Validation Needed." {
                send(["type": "validation", "topic": "", "data": Go2Protocol.validationReply(challenge)])
            }
        case "heartbeat":
            lastHeartbeatAck = Date()
        case "res":
            resolve(msg)
        default:
            if (msg["topic"] as? String) == "rt/lf/sportmodestate",
               let data = msg["data"] as? [String: Any],
               let h = (data["body_height"] as? NSNumber)?.doubleValue {
                bodyHeight = h
                bodyHeightAt = Date()
            } else if (msg["topic"] as? String) == "rt/lf/lowstate",
               Date().timeIntervalSince(lastBatteryUpdate) > 1,
               let data = msg["data"] as? [String: Any],
               let bms = data["bms_state"] as? [String: Any],
               let soc = bms["soc"] as? Int {
                battery = soc
                lastBatteryUpdate = Date()
            }
        }
    }

    /// Text frames are JSON; binary frames carry a JSON header (lidar frames are ignored).
    nonisolated static func decode(_ buffer: RTCDataBuffer) -> [String: Any]? {
        let d = buffer.data
        if !buffer.isBinary {
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        guard d.count >= 4 else { return nil }
        let h1 = UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8
        let h2 = UInt16(d[d.startIndex + 2]) | UInt16(d[d.startIndex + 3]) << 8
        if h1 == 2 && h2 == 0 { return nil }
        let len = Int(h1)
        guard d.count >= 4 + len else { return nil }
        return try? JSONSerialization.jsonObject(with: d.subdata(in: d.startIndex + 4 ..< d.startIndex + 4 + len)) as? [String: Any]
    }
}

extension Go2Connection: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let name = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed", "count"][min(Int(newState.rawValue), 7)]
        Task { @MainActor in
            self.ice = name
            if newState == .failed || newState == .disconnected { self.note("ICE \(name)") }
            if newState == .failed, self.pc != nil { self.fail("ICE failed") }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in if newState == .complete { self.finishGathering() } }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let name = ["new", "connecting", "connected", "disconnected", "failed", "closed"][min(Int(newState.rawValue), 5)]
        Task { @MainActor in
            self.peer = name
            self.note("peer \(name)")
            if newState == .failed || newState == .disconnected, self.pc != nil { self.fail("robot link \(name)") }
        }
    }
}

extension Go2Connection: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let name = ["connecting", "open", "closing", "closed"][min(Int(dataChannel.readyState.rawValue), 3)]
        Task { @MainActor in
            self.channel = name
            self.note("data channel \(name)")
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in self.handle(buffer) }
    }
}
