import UIKit
import Combine
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var streaming = false
    @Published private(set) var starting = false
    @Published private(set) var cameraActive = false
    @Published private(set) var frame: UIImage?
    @Published private(set) var status = "Link your glasses"
    @Published var error: String?
    private var configured = false
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var tokens: [any AnyListenerToken] = []
    private var observers: [Task<Void, Never>] = []
    private var lastFrameAt = Date.distantPast
    private var generation = UUID()

    func configure() {
        guard !configured else { return }
        do { try Wearables.configure(); configured = true }
        catch { self.error = error.localizedDescription; return }
        observers.append(Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                self.registered = state == .registered
                self.status = state == .registered ? "Linked to Meta AI" : "Link your glasses"
                if state != .registered { self.stop() }
            }
        })
        observers.append(Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                self?.deviceCount = devices.count
            }
        })
    }

    func register() async {
        configure()
        guard configured else { return }
        do { try await Wearables.shared.startRegistration() }
        catch { self.error = error.localizedDescription }
    }

    func handle(_ url: URL) async {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        configure()
        guard configured else { return }
        do { _ = try await Wearables.shared.handleUrl(url) }
        catch { self.error = error.localizedDescription }
    }

    func start() async throws {
        guard camera == nil, !starting else { return }
        guard registered else { throw CJError("Link your glasses with Meta AI first.") }
        guard UIApplication.shared.applicationState == .active else { throw CJError("Open CJ on your iPhone to use the glasses camera.") }
        starting = true
        let generation = UUID()
        self.generation = generation
        defer { starting = false }
        do {
            let permission = try await Wearables.shared.requestPermission(.camera)
            guard permission == .granted else { throw CJError("Allow camera access in Meta AI to share what you see.") }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            let session = try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
            deviceSession = session
            try session.start()
            for _ in 0..<80 {
                if session.state == .started { break }
                try await Task.sleep(for: .milliseconds(100))
                guard self.generation == generation else { throw CancellationError() }
            }
            guard session.state == .started else { throw CJError("Glasses didn’t connect. Open their arms, put them on, and try again.") }
            guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 6)) else {
                throw CJError("The glasses camera is unavailable.")
            }
            self.camera = camera
            cameraActive = true
            tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                let image = frame.makeUIImage()
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.frame = image; self.lastFrameAt = Date()
                }
            })
            tokens.append(camera.stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.streaming = state == .streaming
                    self.status = state == .streaming ? "Camera is live" : "Camera: \(state)"
                    if state == .stopped { self.stop() }
                }
            })
            tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.error = error.localizedDescription; self.stop()
                }
            })
            tokens.append(session.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    if state == .stopped || state == .paused { self.stop() }
                }
            })
            camera.stream.start()
        } catch {
            if self.generation == generation { stop() }
            throw error
        }
    }

    /// A fresh frame from the glasses stream; no experimental high-resolution photo APIs needed.
    func capture() async throws -> Data {
        let alreadyRunning = camera != nil
        if !alreadyRunning { try await start() }
        defer { if !alreadyRunning { stop() } }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if Date().timeIntervalSince(lastFrameAt) < 1, let data = frame?.jpegData(compressionQuality: 0.75) { return data }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CJError("No recent camera frame. Check that the glasses are connected and being worn.")
    }

    func stop() {
        generation = UUID()
        let oldTokens = tokens
        tokens.removeAll()
        Task { for token in oldTokens { await token.cancel() } }
        camera?.stop(); camera = nil
        deviceSession?.stop(); deviceSession = nil
        streaming = false; starting = false; cameraActive = false; frame = nil; lastFrameAt = .distantPast
        status = registered ? "Linked to Meta AI" : "Link your glasses"
    }

    func enteredBackground() {
        // The Meta AI permission handoff backgrounds CJ before a session exists.
        // Allow that handoff to finish; stop any actual camera session immediately.
        if deviceSession != nil { stop() }
    }
}
