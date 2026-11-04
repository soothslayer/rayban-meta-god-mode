import Foundation

// Do not forward the pairing credential through redirects to an unrelated server.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct BrainClient {
    let pairing: Pairing
    let session: URLSession

    init(pairing: Pairing, session: URLSession? = nil) {
        self.pairing = pairing
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func call(_ path: String, body: Data? = nil) async throws -> Data {
        var request = pairing.request(path: path)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CJError("The Mac returned an invalid response.") }
        if response.statusCode == 401 { throw CJError("The Mac rejected the pairing token. Scan its QR code again.") }
        guard (200..<300).contains(response.statusCode) else {
            // Avoid displaying server exception bodies, which can contain credentials or private data.
            throw CJError("The Mac returned HTTP \(response.statusCode). Check the brain’s terminal for details.")
        }
        return data
    }

    func verify() async throws -> Health {
        let health = try JSONDecoder().decode(Health.self, from: await call("/health"))
        guard health.ok, health.name == "CJ" else { throw CJError("This address isn’t a CJ brain.") }
        // /health is intentionally public. Verify the token against a read-only authenticated endpoint too.
        _ = try await call("/api/memory")
        return health
    }

    func ask(_ text: String, history: [Turn], image: Data?) async throws -> Answer {
        struct Request: Encodable {
            let text: String
            let history: [Turn]
            let image_b64: String?
            let mime = "image/jpeg"
            let voice = true
        }
        let body = try JSONEncoder().encode(Request(text: text, history: Array(history.suffix(8)), image_b64: image?.base64EncodedString()))
        return try JSONDecoder().decode(Answer.self, from: await call("/api/ask", body: body))
    }
}
