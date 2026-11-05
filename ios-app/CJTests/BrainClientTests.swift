import XCTest
#if canImport(CJ)
@testable import CJ
#else
@testable import CJCore
#endif

final class StubProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class BrainClientTests: XCTestCase {
    private func client() throws -> BrainClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return BrainClient(pairing: try Pairing(address: "http://mac.local:8765", token: "test-secret"), session: URLSession(configuration: config))
    }
    override func tearDown() { StubProtocol.respond = nil; super.tearDown() }

    func testPairingChecksAuthEvenThoughHealthIsPublic() async throws {
        var paths: [String] = []
        StubProtocol.respond = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            if request.url!.path == "/health" { return (200, #"{"name":"CJ","ok":true,"providers":{"mock":true}}"#) }
            return (401, #"{"detail":"bad token"}"#)
        }
        do { _ = try await client().verify(); XCTFail("A rejected token must fail pairing") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rejected")) }
        XCTAssertEqual(paths, ["/health", "/api/memory"])
    }

    func testAskSendsPhotoAndOnlyRecentHistory() async throws {
        let conversation = UUID()
        StubProtocol.respond = { request in
            XCTAssertEqual(request.url!.path, "/api/ask")
            XCTAssertEqual(request.httpMethod, "POST")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((json["history"] as? [[String: String]])?.count, 8)
            XCTAssertEqual(json["conversation_id"] as? String, conversation.uuidString)
            XCTAssertEqual(json["image_b64"] as? String, "AQID")
            XCTAssertEqual(json["voice"] as? Bool, true)
            return (200, #"{"spoken":"A sample reply","language":"en"}"#)
        }
        let answer = try await client().ask("What is this?", history: (0..<12).map { Turn(role: "user", text: "Turn \($0)") }, image: Data([1,2,3]), conversationID: conversation)
        XCTAssertEqual(answer.spoken, "A sample reply")
    }

    func testServerErrorsDoNotExposeBody() async throws {
        StubProtocol.respond = { _ in (502, "secret-api-key") }
        do { _ = try await client().ask("hello", history: [], image: nil); XCTFail("Expected HTTP error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("502")); XCTAssertFalse(error.localizedDescription.contains("secret-api-key")) }
    }

    func testSubscriptionHealthSelectsLocalVoice() async throws {
        StubProtocol.respond = { _ in (200, #"{"name":"CJ","ok":true,"providers":{"codex":true},"assistant":"codex","voice_mode":"local"}"#) }
        let health = try await client().health()
        XCTAssertEqual(health.assistant, "codex")
        XCTAssertEqual(health.voice_mode, "local")
    }

    func testSubscriptionSignInErrorIsActionable() async throws {
        StubProtocol.respond = { _ in (503, #"{"detail":"Sign in on your Mac using codex login."}"#) }
        do { _ = try await client().ask("hello", history: [], image: nil, assistant: "codex"); XCTFail("Expected sign-in error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("codex login")) }
    }
}
