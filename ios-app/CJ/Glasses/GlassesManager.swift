import UIKit
import Combine
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    @Published private(set) var registered = false
    @Published private(set) var deviceCount = 0
    @Published private(set) var cameraReady = false
    @Published private(set) var streaming = false
    @Published private(set) var starting = false
    @Published private(set) var cameraActive = false
    @Published private(set) var frame: UIImage?
    @Published private(set) var status = "Link your glasses"
    @Published var error: String?
    private var configured = false
    private var deviceSelector: AutoDeviceSelector?
    private var deviceSession: DeviceSession?
    private var sessionError: DeviceSessionError?
    private var camera: MWDATCamera.Camera?
    private var tokens: [any AnyListenerToken] = []
    private var observers: [Task<Void, Never>] = []
    private var lastFrameAt = Date.distantPast
    private var generation = UUID()

    func configure() {
        guard !configured else { return }
        do { try Wearables.configure(); configured = true }
        catch { self.error = error.localizedDescription; return }
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        deviceSelector = selector
        registered = Wearables.shared.registrationState == .registered
        deviceCount = Wearables.shared.devices.count
        updateIdleStatus()
        observers.append(Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                self.registered = state == .registered
                if state != .registered { self.stop() }
                else { self.updateIdleStatus() }
            }
        })
        observers.append(Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                self?.deviceCount = devices.count
            }
        })
        observers.append(Task { [weak self] in
            // Registration/discovery can complete before the connection handshake.
            // Retain this selector and observe readiness before creating a session.
            for await device in selector.activeDeviceStream() {
                guard let self else { return }
                self.cameraReady = device != nil
                self.updateIdleStatus()
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
        guard !starting else { throw CJError("The glasses camera is still connecting. Wait for the preview, then try again.") }
        guard camera == nil else { return }
        guard registered else { throw CJError("Link your glasses with Meta AI first.") }
        guard let selector = deviceSelector else { throw CJError("Open CJ again to reconnect to your glasses.") }
        guard UIApplication.shared.applicationState == .active else { throw CJError("Open CJ on your iPhone to use the glasses camera.") }
        starting = true
        error = nil
        sessionError = nil
        status = "Checking camera access…"
        let generation = UUID()
        self.generation = generation
        defer { if self.generation == generation { starting = false } }
        do {
            var permission = try await Wearables.shared.checkPermissionStatus(.camera)
            try validateAttempt(generation)
            if permission != .granted {
                permission = try await Wearables.shared.requestPermission(.camera)
            }
            try validateAttempt(generation)
            guard permission == .granted else { throw CJError("Allow camera access in Meta AI to share what you see.") }
            status = "Waiting for glasses to connect…"
            // Permission may return before CJ is active or the selector has a
            // connected, compatible device. A newly created selector is not ready.
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while selector.activeDevice == nil || UIApplication.shared.applicationState != .active {
                try validateAttempt(generation)
                guard ContinuousClock.now < deadline else {
                    if UIApplication.shared.applicationState != .active {
                        throw CJError("Return to CJ on your iPhone, then try the glasses camera again.")
                    }
                    throw CJError(unavailableMessage())
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try validateAttempt(generation)
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            deviceSession = session
            tokens.append(session.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.sessionError = error
                    if !self.starting {
                        self.error = self.cameraErrorMessage(error)
                        self.stop()
                    }
                }
            })
            status = "Starting glasses camera…"
            try session.start()
            for _ in 0..<80 {
                try validateAttempt(generation)
                if let sessionError { throw sessionError }
                if session.state == .started { break }
                if session.state == .stopped || session.state == .paused {
                    throw CJError("The glasses connection stopped. Put the glasses on and try Preview again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try validateAttempt(generation)
            if let sessionError { throw sessionError }
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
            guard self.generation == generation else { throw CancellationError() }
            let message = cameraErrorMessage(error)
            stop()
            if error is CancellationError { throw error }
            throw CJError(message)
        }
    }

    private func validateAttempt(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func updateIdleStatus() {
        guard !starting, !cameraActive else { return }
        status = !registered ? "Link your glasses" : cameraReady ? "Glasses ready for camera" : "Linked to Meta AI · Waiting for glasses"
    }

    private func unavailableMessage() -> String {
        let devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
        if devices.contains(where: { $0.compatibility() == .deviceUpdateRequired }) {
            return "Your glasses need an update. Open Meta AI, update the glasses, then try Preview again."
        }
        if devices.contains(where: { $0.compatibility() == .sdkUpdateRequired }) {
            return "CJ needs a newer Meta glasses SDK to connect to these glasses. Update CJ before trying the camera again."
        }
        return "CJ is linked to Meta AI, but no glasses are ready for camera access. Wear the glasses with their arms open, confirm they are connected in Meta AI with Developer Mode enabled, then return to CJ and try Preview again."
    }

    private func cameraErrorMessage(_ error: Error) -> String {
        if let sessionError = error as? DeviceSessionError, sessionError == .noEligibleDevice {
            return unavailableMessage()
        }
        return error.localizedDescription
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
        sessionError = nil
        streaming = false; starting = false; cameraActive = false; frame = nil; lastFrameAt = .distantPast
        updateIdleStatus()
    }

    func enteredBackground() {
        // The Meta AI permission handoff backgrounds CJ before a session exists.
        // Allow that handoff to finish; stop any actual camera session immediately.
        if deviceSession != nil { stop() }
    }
}
