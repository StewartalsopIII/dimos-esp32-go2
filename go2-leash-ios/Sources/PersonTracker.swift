// The dog's own front camera, watched for people on the phone with Apple Vision (no cloud).
// Frames arrive from WebRTC's decoder thread; at most ~10 per second are checked, the rest
// dropped. The target is the largest person box (the one holding the leash is usually closest).
// Steering from that box lives in Go2Connection.followCommand.

import SwiftUI
import Vision
import WebRTC

struct FollowTarget {
    /// Vision coordinates: 0...1, origin bottom-left.
    let box: CGRect
    let people: Int
    let at: Date
    var centerX: Double { box.midX }
    var height: Double { box.height }
    var feet: Double { box.minY }
}

final class PersonTracker: NSObject, ObservableObject, RTCVideoRenderer {
    @MainActor @Published var target: FollowTarget?
    @MainActor @Published var fps = 0.0
    @MainActor @Published var status = "no video"
    @MainActor @Published var videoSize = CGSize(width: 16, height: 9)
    @MainActor var onNote: ((String) -> Void)?

    static let interval: TimeInterval = 0.1
    private let queue = DispatchQueue(label: "go2leash.vision")
    private let lock = NSLock()
    private var busy = false
    private var lastRun = Date.distantPast
    private var frames = 0
    private var framesSince = Date()
    private var warnedFormat = false

    // MARK: RTCVideoRenderer (WebRTC decoder thread)

    func setSize(_ size: CGSize) {
        Task { @MainActor in
            if size.width > 0, size.height > 0 { self.videoSize = size }
            self.onNote?("dog video \(Int(size.width))×\(Int(size.height))")
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        frames += 1
        let now = Date()
        if now.timeIntervalSince(framesSince) >= 1 {
            let f = Double(frames) / now.timeIntervalSince(framesSince)
            frames = 0
            framesSince = now
            Task { @MainActor in self.fps = f }
        }
        let run = !busy && now.timeIntervalSince(lastRun) >= Self.interval
        if run { busy = true; lastRun = now }
        lock.unlock()
        guard run else { return }
        guard let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            lock.lock(); busy = false; let warn = !warnedFormat; warnedFormat = true; lock.unlock()
            if warn { Task { @MainActor in self.status = "video is not a pixel buffer; no detection" } }
            return
        }
        queue.async { self.detect(buffer, rotation: frame.rotation) }
    }

    // MARK: Vision (own queue)

    private func detect(_ buffer: CVPixelBuffer, rotation: RTCVideoRotation) {
        defer { lock.lock(); busy = false; lock.unlock() }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let orientation: CGImagePropertyOrientation =
            rotation == ._90 ? .right : rotation == ._180 ? .down : rotation == ._270 ? .left : .up
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            Task { @MainActor in self.status = "vision error: \(error.localizedDescription)" }
            return
        }
        let people = request.results ?? []
        let best = people.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        Task { @MainActor in
            self.status = people.isEmpty ? "no person" : "\(people.count) person\(people.count == 1 ? "" : "s")"
            guard let best else { return }
            // Smooth a fresh box with the last one so one jumpy frame cannot flip the turn.
            var box = best.boundingBox
            if let last = self.target, Date().timeIntervalSince(last.at) <= 0.5 {
                let a = 0.4
                box = CGRect(x: last.box.minX + a * (box.minX - last.box.minX),
                             y: last.box.minY + a * (box.minY - last.box.minY),
                             width: last.box.width + a * (box.width - last.box.width),
                             height: last.box.height + a * (box.height - last.box.height))
            }
            self.target = FollowTarget(box: box, people: people.count, at: Date())
        }
    }
}

/// The dog's video, drawn with Metal.
struct DogVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        track.add(view)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {}

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: ()) {}
}

/// Full-screen dog's-eye view: video, the person box, the follow numbers, Disarm.
struct FollowView: View {
    @ObservedObject var go2: Go2Connection
    @ObservedObject var tracker: PersonTracker
    let close: () -> Void
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = go2.videoTrack {
                GeometryReader { geo in
                    let frame = Self.fit(tracker.videoSize, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        DogVideoView(track: track)
                        if let t = tracker.target, now.timeIntervalSince(t.at) <= Go2Connection.personFreshness {
                            Rectangle()
                                .stroke(go2.moving ? .green : .yellow, lineWidth: 3)
                                .frame(width: t.box.width * frame.width, height: t.box.height * frame.height)
                                .offset(x: t.box.minX * frame.width, y: (1 - t.box.maxY) * frame.height)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                Text("waiting for the dog's video").foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text(stateLine)
                    .font(.headline.monospaced())
                    .foregroundStyle(go2.moving ? .green : .white)
                    .padding(8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Text(numbersLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                HStack {
                    Button("Close", action: close).buttonStyle(.bordered).tint(.white)
                    Spacer()
                    Button("Disarm", role: .destructive) { go2.disarm("operator (follow view)") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!go2.armed)
                }
            }
            .padding()
        }
        .onReceive(tick) { now = $0 }
    }

    private var stateLine: String {
        guard go2.connected else { return "dog: not connected" }
        let state = go2.moving ? "FOLLOWING" : go2.armed ? (go2.followMode ? "ARMED · hold to follow" : "ARMED · follow mode off") : "not armed"
        return "dog: \(state)" + (go2.battery.map { " · \($0)%" } ?? "")
    }

    private var numbersLine: String {
        var s = String(format: "%.0f fps · %@", tracker.fps, tracker.status)
        if let t = tracker.target, now.timeIntervalSince(t.at) <= Go2Connection.personFreshness {
            let (x, z) = Go2Connection.followCommand(t)
            s += String(format: " · x %.2f feet %.2f → fwd %.2f turn %+.2f", t.centerX, t.feet, x, z)
        }
        return s
    }

    static func fit(_ aspect: CGSize, in size: CGSize) -> CGSize {
        let scale = min(size.width / aspect.width, size.height / aspect.height)
        return CGSize(width: aspect.width * scale, height: aspect.height * scale)
    }
}
