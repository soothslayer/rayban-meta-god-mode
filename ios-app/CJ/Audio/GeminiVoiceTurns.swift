import Foundation

/// Preserves the Gemini Live session and native audio while resolving short controls locally.
@MainActor
final class GeminiVoiceTurns {
    let pairing: Pairing
    let language: String
    var onAudio: ((Data) async throws -> Void)?
    var onSaid: ((String) -> Void)?
    var photo: (() async throws -> Data)?
    var onPhone: ((PhoneAction) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?

    init(pairing: Pairing, language: String) {
        self.pairing = pairing
        self.language = language
    }

    func connect(history: [Turn]) async throws {
        if socket != nil { return }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: pairing.request(path: "/ws/live", websocket: true))
        self.session = session
        self.socket = socket
        socket.maximumMessageSize = 2_000_000
        socket.resume()
        struct Start: Encodable {
            let type = "start", mode = "assistant", manual_voice_turns = true
            let transcription_language: String
            let history: [Turn]
        }
        let start = Start(transcription_language: language, history: Array(history.suffix(8)))
        try await socket.send(.string(String(decoding: JSONEncoder().encode(start), as: UTF8.self)))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        guard case .string(let text) = try await socket.receive() else { throw CJError("Unexpected Gemini startup response.") }
        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8))
        guard event.type == "ready" else { throw CJError(event.text ?? "Gemini could not start.") }
    }

    func reply(to audio: Data, history: [Turn]) async throws -> (String, Bool) {
        try await connect(history: history)
        try Task.checkCancellation()
        guard let socket else { throw CancellationError() }
        try await socket.send(.string(#"{"type":"activityStart"}"#))
        for offset in stride(from: 0, to: audio.count, by: 16_000) {
            try Task.checkCancellation()
            try await socket.send(.data(audio.subdata(in: offset..<min(offset + 16_000, audio.count))))
        }
        try await socket.send(.string(#"{"type":"activityEnd"}"#))
        var said = ""
        while !Task.isCancelled {
            let message = try await socket.receive()
            try Task.checkCancellation()
            switch message {
            case .data(let bytes): try await onAudio?(bytes)
            case .string(let text):
                let event = try JSONDecoder().decode(LiveEvent.self, from: Data(text.utf8))
                switch event.type {
                case "said": said += event.text ?? ""; onSaid?(said)
                case "turn_done": return (event.said ?? said, event.ending == true)
                case "end": return (said, true)
                case "error": throw CJError(event.text ?? "Gemini disconnected.")
                case "need_photo":
                    let image = try? await photo?()
                    try Task.checkCancellation()
                    let data = try JSONEncoder().encode(["type": "photo", "image_b64": image?.base64EncodedString() ?? ""])
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                case "phone":
                    if let action = event.action {
                        onPhone?(PhoneAction(action: action, number: event.number, seconds: event.seconds, label: event.label))
                    }
                default: break
                }
            @unknown default: break
            }
        }
        throw CancellationError()
    }

    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
