import Foundation

struct CJError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Pairing: Codable, Equatable {
    let url: URL
    let token: String

    init(address: String, token: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw CJError("Enter the Mac’s address, such as http://192.168.1.20:8765, without a path or query.")
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 512,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw CJError("Enter the pairing token from your Mac.")
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw CJError("Invalid Mac address.") }
        self.url = url
        self.token = token
    }

    static func parse(qr: String) throws -> Pairing {
        struct Payload: Decodable { let v: Int; let url: String; let token: String }
        guard let data = qr.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.v == 1 else {
            throw CJError("This isn’t a CJ pairing code. Run brain/run.sh on your Mac and scan its QR code.")
        }
        return try Pairing(address: payload.url, token: payload.token)
    }

    func request(path: String, websocket: Bool = false) -> URLRequest {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = path
        if websocket { parts.scheme = url.scheme == "https" ? "wss" : "ws" }
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        return request
    }
}

struct Turn: Codable, Identifiable {
    var id = UUID()
    let role: String
    let text: String
    enum CodingKeys: String, CodingKey { case role, text }
}

struct PhoneAction: Decodable {
    let action: String
    var number: String?
    var seconds: Int?
    var label: String?
}

struct TimerRequest: Decodable { let seconds: Int; let label: String }

struct Answer: Decodable {
    let spoken: String
    var details: String?
    var language: String?
    var voice_b64: String?
    var phone: PhoneAction?
    var timer: TimerRequest?
    var dictation: String?
}

struct LiveEvent: Decodable {
    let type: String
    var text: String?
    var heard: String?
    var said: String?
    var action: String?
    var seconds: Int?
    var label: String?
    var number: String?
}

struct Health: Decodable {
    let name: String
    let ok: Bool
    let providers: [String: Bool]
    var assistant: String?
    var voice_mode: String?
}
