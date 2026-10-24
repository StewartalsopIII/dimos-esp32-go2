// Films from inside the app so it stays in the foreground: iOS suspends a backgrounded app,
// which drops the dog link and (by design) disarms. Back camera + mic to a temp .mov, then
// saved to Photos (add-only access) and the temp file removed.

import AVFoundation
import Photos
import SwiftUI

@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    @Published var status = "camera off"
    @Published var recording = false
    @Published var startedAt: Date?
    var onNote: ((String) -> Void)?

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var configured = false
    private let queue = DispatchQueue(label: "go2leash.camera")

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "camera not allowed (Settings)"
            return
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        if !configured {
            guard configure(mic: mic) else { return }
            if !mic { onNote?("camera: microphone not allowed, filming without sound") }
        }
        let s = session
        queue.async { s.startRunning() }
        status = "ready"
    }

    func stop() {
        stopRecording()
        let s = session
        queue.async { s.stopRunning() }
        status = "camera off"
    }

    func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func configure(mic: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
            status = "no camera"
            return false
        }
        session.addInput(input)
        if mic, let m = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: m), session.canAddInput(input) {
            session.addInput(input)
        }
        guard session.canAddOutput(output) else {
            status = "cannot record"
            return false
        }
        session.addOutput(output)
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90                       // portrait, like the app
        }
        configured = true
        return true
    }

    private func startRecording() {
        guard configured, !output.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("go2-\(Int(Date().timeIntervalSince1970)).mov")
        output.startRecording(to: url, recordingDelegate: self)
        recording = true
        startedAt = Date()
        onNote?("camera: recording")
    }

    private func stopRecording() {
        if output.isRecording { output.stopRecording() }
    }

    fileprivate func finished(_ url: URL, _ error: Error?) {
        recording = false
        startedAt = nil
        // A recording cut short (e.g. interruption) can still be complete and playable.
        let ok = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            onNote?("camera: recording failed (\(error?.localizedDescription ?? "no file"))")
            return
        }
        Task { await save(url) }
    }

    private func save(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            onNote?("camera: NOT saved, Photos access denied (Settings)")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            onNote?("camera: saved to Photos")
        } catch {
            onNote?("camera: save failed (\(error.localizedDescription))")
        }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.finished(url, error) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Full-screen camera with the dog's state on top; the walk timers keep running underneath.
struct FilmView: View {
    @ObservedObject var go2: Go2Connection
    @ObservedObject var camera: CameraRecorder
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Text(dogLine)
                        .font(.headline.monospaced())
                        .foregroundStyle(go2.moving ? .green : .white)
                        .padding(8)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    if camera.recording, let t = camera.startedAt {
                        TimelineView(.periodic(from: t, by: 1)) { ctx in
                            Text("● " + Self.clock(ctx.date.timeIntervalSince(t)))
                                .font(.headline.monospaced())
                                .foregroundStyle(.red)
                                .padding(8)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if camera.status != "ready" {
                    Text(camera.status).foregroundStyle(.yellow)
                }
                Spacer()
                HStack {
                    Button("Close", action: close)
                        .buttonStyle(.bordered).tint(.white)
                    Spacer()
                    Button(action: camera.toggleRecording) {
                        Circle()
                            .fill(.red)
                            .frame(width: camera.recording ? 40 : 64, height: camera.recording ? 40 : 64)
                            .frame(width: 76, height: 76)
                            .overlay(Circle().stroke(.white, lineWidth: 4))
                    }
                    .disabled(camera.status != "ready")
                    Spacer()
                    Button("Disarm", role: .destructive) { go2.disarm("operator (camera)") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!go2.armed)
                }
            }
            .padding()
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private var dogLine: String {
        guard go2.connected else { return "dog: not connected" }
        let state = go2.moving ? (go2.walkDir > 0 ? "FORWARD" : "BACKWARD") : go2.armed ? "ARMED" : "not armed"
        return "dog: \(state)" + (go2.battery.map { " · \($0)%" } ?? "")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
