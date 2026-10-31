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
    var photo: (() async throws -> Data)?
    private let audio = LiveAudio()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func start(pairing: Pairing, history: [Turn]) {
        guard !active else { return }
        active = true
        heard = ""; said = ""
        status = "Connecting to your Mac…"
        let generation = UUID()
        self.generation = generation
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
                self.session = session
                let socket = session.webSocketTask(with: pairing.request(path: "/ws/live", websocket: true))
                self.socket = socket
                socket.maximumMessageSize = 2_000_000
                socket.resume()
                struct Start: Encodable { let type = "start"; let mode = "assistant"; let history: [Turn] }
                let start = try JSONEncoder().encode(Start(history: Array(history.suffix(8))))
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
                    case .data(let data): try self.audio.play(data)
                    case .string(let text):
                        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8))
                        if event.type == "ready" {
                            self.audio.onFailure = { [weak self] in self?.fail($0) }
                            let frames = try await self.audio.start()
                            try Task.checkCancellation()
                            self.timeout?.cancel()
                            self.route = self.audio.route
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
                                if !self.audio.isPlaying { break }
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
                    self.fail(unauthorized ? "Pairing was rejected. Scan the Mac’s QR code again." : "Live voice disconnected. Check the Mac’s terminal, pairing token, and Wi-Fi.")
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
        case "interrupted": audio.interrupt(); said = ""; status = "Listening…"
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

    private func fail(_ message: String) { stop(); onFailure?(message) }

    func stop() {
        generation = UUID()
        receiver?.cancel(); sender?.cancel(); photoTask?.cancel(); timeout?.cancel()
        receiver = nil; sender = nil; photoTask = nil; timeout = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel(); session = nil
        audio.stop()
        active = false
        status = "Ready when you are"
        heard = ""; said = ""
    }
}
