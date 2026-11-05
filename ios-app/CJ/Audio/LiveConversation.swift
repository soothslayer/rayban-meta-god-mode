import Foundation
import Combine

@MainActor
final class LiveConversation: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var status = "Ready when you are"
    @Published private(set) var heard = ""
    @Published private(set) var said = ""
    @Published private(set) var route = ""
    var onTurn: ((String, String) -> Void)?
    var onPhone: ((PhoneAction) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStopped: ((Bool, VoiceCapture?) -> Void)?
    var keepMicrophoneOnStop = false
    var photo: (() async throws -> Data)?
    private var capture: VoiceCapture?
    private var subscription: SubscriptionConversation?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func start(pairing: Pairing, history: [Turn], conversationID: UUID, transcriptionLanguage: String, preparedCapture: VoiceCapture? = nil) {
        guard !active else { preparedCapture?.stop(); return }
        capture = preparedCapture
        capture?.onFailure = { [weak self] in self?.fail($0) }
        active = true
        heard = ""; said = ""
        status = "Connecting to your Mac…"
        let generation = UUID()
        self.generation = generation
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await BrainClient(pairing: pairing).health()
                try Task.checkCancellation()
                if health.voice_mode == "local", let provider = health.assistant, ["codex", "claude-code", "muse"].contains(provider) {
                    let capture = self.capture ?? VoiceCapture()
                    self.capture = capture
                    capture.onFailure = { [weak self] in self?.fail($0) }
                    let subscription = SubscriptionConversation(capture: capture, pairing: pairing, provider: provider,
                        language: transcriptionLanguage, history: history, conversationID: conversationID)
                    self.subscription = subscription
                    subscription.photo = self.photo
                    subscription.onHeard = { [weak self] in self?.heard = $0 }
                    subscription.onSaid = { [weak self] in self?.said = $0 }
                    subscription.onStatus = { [weak self] in self?.status = $0 }
                    subscription.onTurn = { [weak self] in self?.onTurn?($0, $1) }
                    subscription.onEnd = { [weak self] in self?.stop() }
                    subscription.onFailure = { [weak self] in self?.fail($0) }
                    try await subscription.start()
                    self.route = capture.audio.route
                    return
                }
                let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
                self.session = session
                let socket = session.webSocketTask(with: pairing.request(path: "/ws/live", websocket: true))
                self.socket = socket
                socket.maximumMessageSize = 2_000_000
                socket.resume()
                struct Start: Encodable {
                    let type = "start"
                    let mode = "assistant"
                    let history: [Turn]
                    let transcription_language: String
                }
                let start = try JSONEncoder().encode(Start(history: Array(history.suffix(8)), transcription_language: transcriptionLanguage))
                try await socket.send(.string(String(decoding: start, as: UTF8.self)))
                self.timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.fail("The Mac didn’t start live voice. Check its Gemini key and Wi-Fi connection.")
                }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    switch message {
                    case .data(let data):
                        guard let capture = self.capture, capture.started else {
                            throw CJError("Reply audio arrived before the microphone was ready.")
                        }
                        try capture.audio.play(data)
                    case .string(let text):
                        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8))
                        if event.type == "ready" {
                            let capture = self.capture ?? VoiceCapture()
                            self.capture = capture
                            capture.onFailure = { [weak self] in self?.fail($0) }
                            try await capture.start()
                            try Task.checkCancellation()
                            let frames = capture.conversationFrames()
                            self.timeout?.cancel()
                            self.route = capture.audio.route
                            self.status = "Listening · say “bye” to finish"
                            self.sender = Task {
                                do {
                                    for await frame in frames {
                                        try Task.checkCancellation()
                                        try await socket.send(.data(frame))
                                    }
                                } catch {
                                    if !Task.isCancelled, self.generation == generation { self.fail("Live audio disconnected. Check the Mac and your Wi-Fi.") }
                                }
                            }
                        } else if event.type == "end" {
                            self.sender?.cancel()
                            self.status = "Finishing…"
                            for _ in 0..<300 {
                                if self.capture?.audio.isPlaying != true { break }
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            self.stop()
                            return
                        } else {
                            self.handle(event, socket: socket)
                        }
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled, self.generation == generation {
                    let unauthorized = self.socket?.closeCode.rawValue == 4401
                    self.fail(unauthorized ? "Pairing was rejected. Scan the Mac’s QR code again." : (error as? CJError)?.localizedDescription ?? "Live voice disconnected. Check the Mac’s terminal, pairing token, and Wi-Fi.")
                }
            }
        }
    }

    private func handle(_ event: LiveEvent, socket: URLSessionWebSocketTask) {
        switch event.type {
        case "heard": heard += event.text ?? ""
        case "said": said += event.text ?? ""; status = "CJ is speaking"
        case "turn_done":
            onTurn?(event.heard ?? heard, event.said ?? said)
            heard = ""; said = ""
            status = "Listening · say “bye” to finish"
        case "interrupted": capture?.audio.interrupt(); said = ""; status = "Listening…"
        case "error": fail(event.text ?? "The Mac couldn’t start live voice.")
        case "phone":
            if let action = event.action {
                onPhone?(PhoneAction(action: action, number: event.number, seconds: event.seconds, label: event.label))
            }
        case "need_photo":
            photoTask?.cancel()
            photoTask = Task { [weak self] in
                guard let self else { return }
                var encoded = ""
                do {
                    guard let photo = self.photo else { throw CJError("Connect glasses to share what you see.") }
                    encoded = try await photo().base64EncodedString()
                } catch {
                    self.onFailure?(error.localizedDescription)
                }
                guard !Task.isCancelled else { return }
                let response = ["type": "photo", "image_b64": encoded]
                if let data = try? JSONEncoder().encode(response) {
                    try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
                }
            }
        default: break // Future events can be added without breaking existing sessions.
        }
    }

    private func fail(_ message: String) { stop(resumeWake: false); onFailure?(message) }

    func stop(resumeWake: Bool = true) {
        let wasActive = active
        generation = UUID()
        subscription?.stop(); subscription = nil
        receiver?.cancel(); sender?.cancel(); photoTask?.cancel(); timeout?.cancel()
        receiver = nil; sender = nil; photoTask = nil; timeout = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel(); session = nil
        let retainedCapture = keepMicrophoneOnStop && resumeWake && capture?.started == true ? capture : nil
        if let retainedCapture { retainedCapture.prepareForWakeWord() }
        else { capture?.stop() }
        capture = nil
        active = false
        status = "Ready when you are"
        heard = ""; said = ""
        if wasActive { onStopped?(resumeWake, retainedCapture) }
        else { retainedCapture?.stop() }
    }
}
