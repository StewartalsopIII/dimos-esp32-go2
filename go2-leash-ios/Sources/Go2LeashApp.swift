import SwiftUI

@main
struct Go2LeashApp: App {
    var body: some Scene {
        WindowGroup { StatusView() }
    }
}

struct StatusView: View {
    @StateObject private var go2 = Go2Connection()
    @StateObject private var leash = LeashScanner()
    @StateObject private var camera = CameraRecorder()
    @StateObject private var tracker = PersonTracker()
    @State private var filming = false
    @State private var watching = false
    @State private var keyPresent = false
    @State private var now = Date()
    @Environment(\.scenePhase) private var scenePhase
    private let walkTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("After Arm: a BOOT press flips posture. In walk mode, touch the G32 edge (or hold BOOT) = forward, the G4 edge = backward; let go = stop.")
                        .font(.footnote).foregroundStyle(.secondary)
                    row("Robot key", keyPresent ? "in keychain" : "missing")
                    row("Phase", go2.phase)
                    row("ICE / peer", "\(go2.ice) / \(go2.peer)")
                    row("Data channel", go2.channel)
                    row("Validated", go2.validated ? "yes" : "no")
                    row("Heartbeat ack", go2.lastHeartbeatAck.map { "\(Int(now.timeIntervalSince($0))) s ago" } ?? "-")
                    row("Battery", go2.battery.map { "\($0)%" } ?? "-")
                    row("Messages", "\(go2.messages)")
                }
                if go2.connected {
                    Section("Posture") {
                        row("Dog", go2.bodyHeight.map { String(format: "%.2f m · ", $0) + (go2.standing.map { $0 ? "standing" : "lying" } ?? "stale") } ?? "-")
                        Toggle("Walk mode (touch pins = forward/backward)", isOn: $go2.walkMode)
                            .disabled(go2.moving)
                        Toggle("Follow mode (hold = follow the person the dog sees)", isOn: $go2.followMode)
                            .disabled(go2.moving)
                        if go2.followMode { row("Person", tracker.status + String(format: " · %.0f fps", tracker.fps)) }
                        if go2.walkMode { row("Walking", go2.moving ? (go2.walkDir > 0 ? "FORWARD" : "BACKWARD") : "no") }
                        if go2.armed {
                            row("Armed", "until Disarm / board loss")
                            Button("Lie down") { go2.lieDown() }.disabled(go2.busy)
                            Button("Stand up") { go2.standUp() }.disabled(go2.busy)
                            Button("Disarm", role: .destructive) { go2.disarm("operator") }
                        } else {
                            Button("Arm") { go2.arm() }
                                .disabled(go2.busy)
                        }
                        row("Last ack", go2.lastAck)
                    }
                }
                Section {
                    Button("Film (camera stays in this app, dog stays armed)") { filming = true }
                    Button("Dog's view (video + person box)") { watching = true }
                        .disabled(!go2.connected)
                }
                Section("ESP32 leash board") {
                    row("Bluetooth", leash.radio)
                    ForEach(leash.boards.values.sorted { $0.rssi > $1.rssi }) { b in
                        Button {
                            leash.select(b.id)
                        } label: {
                            HStack {
                                Text((leash.selected == b.id ? "● " : "○ ") + "…" + b.id.uuidString.suffix(4))
                                Spacer()
                                Text("\(b.rssi) dBm · \(Self.postureName(b.posture)) #\(b.count)" + (leash.fresh(b, now: now) ? "" : " · stale"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    if go2.phase.hasPrefix("idle") || go2.phase.hasPrefix("failed") || go2.phase.hasPrefix("disconnected") || go2.phase.hasPrefix("no robot key") {
                        Button("Connect") { go2.connect() }.disabled(!keyPresent)
                    } else {
                        Button("Disconnect", role: .destructive) { go2.disconnect() }
                    }
                }
                Section("Log") {
                    ForEach(Array(go2.log.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Go2 Leash")
        }
        .fullScreenCover(isPresented: $filming) {
            FilmView(go2: go2, camera: camera) { filming = false }
        }
        .fullScreenCover(isPresented: $watching) {
            FollowView(go2: go2, tracker: tracker) { watching = false }
        }
        .onChange(of: go2.videoTrack) { old, new in
            old?.remove(tracker)
            new?.add(tracker)
            if new == nil { tracker.status = "no video" }
        }
        .onChange(of: go2.walkMode) { _, on in if on { go2.followMode = false } }
        .onChange(of: go2.followMode) { _, on in if on { go2.walkMode = false } }
        .onAppear {
            if let msg = KeyStore.importDroppedKeyFile() { go2.note(msg) }
            keyPresent = KeyStore.load() != nil
            leash.onNote = { go2.note($0) }
            camera.onNote = { go2.note($0) }
            tracker.onNote = { go2.note($0) }
            go2.onWalkStart = { leash.resetGap() }
            go2.walkStopDetail = { String(format: "max BLE gap %.2f s", leash.maxGap) }
            leash.onGesture = { _, count in
                guard !go2.walkMode, !go2.followMode else { return }
                guard go2.armed else { return go2.note("board press #\(count) ignored: not armed") }
                go2.toggle(from: "board press #\(count)")
            }
            leash.start()
            go2.note("Join the dog's own Wi-Fi in Settings, then Connect.")
        }
        .onReceive(walkTimer) { _ in
            let (dir, age) = leash.held()
            go2.walkTick(dir: dir, heldAge: age, person: tracker.target)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                go2.walkTick(dir: 0, heldAge: .infinity)
                go2.disarm("app not in foreground")
            }
        }
        .onReceive(tick) { t in
            now = t
            UIApplication.shared.isIdleTimerDisabled = go2.connected   // no auto-lock mid-session
            if go2.armed, let id = leash.selected, let b = leash.boards[id], !leash.fresh(b, now: t) {
                go2.disarm(String(format: "board silent %.1f s", t.timeIntervalSince(b.lastSeen)))
            }
        }
    }

    static func postureName(_ p: UInt8) -> String {
        p == 1 ? "SIT" : p == 2 ? "STAND" : "none"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
