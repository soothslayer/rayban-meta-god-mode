import XCTest
#if canImport(CJ)
@testable import CJ
#else
@testable import CJCore
#endif

final class PairingTests: XCTestCase {
    func testParsesExistingBrainQRAndBuildsAuthenticatedWebSocketRequest() throws {
        let pairing = try Pairing.parse(qr: #"{"v":1,"url":"http://192.168.1.20:8765","token":"secret"}"#)
        let request = pairing.request(path: "/ws/live", websocket: true)
        XCTAssertEqual(request.url?.absoluteString, "ws://192.168.1.20:8765/ws/live")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(request.url?.query)
    }

    func testHTTPSAndIPv6() throws {
        let pairing = try Pairing(address: "https://[::1]:8765/", token: "abc")
        XCTAssertEqual(pairing.request(path: "/ws/live", websocket: true).url?.absoluteString, "wss://[::1]:8765/ws/live")
    }

    func testRejectsMalformedOrUnexpectedPairingDestinations() {
        for address in ["", "192.168.1.2", "file:///tmp/test", "http://", "http://user:password@host", "https://example.com/evil", "https://example.com?token=x", "https://example.com#fragment", "http://host:0", "http://host:65536"] {
            XCTAssertThrowsError(try Pairing(address: address, token: "test"), address)
        }
        for token in ["", " ", "injected\r\nHeader:bad", "two words"] {
            XCTAssertThrowsError(try Pairing(address: "http://mac.local:8765", token: token))
        }
        XCTAssertThrowsError(try Pairing.parse(qr: #"{"v":2,"url":"http://mac.local","token":"x"}"#))
        XCTAssertThrowsError(try Pairing.parse(qr: "not-json"))
    }

    func testHistoryMatchesPythonContract() throws {
        let data = try JSONEncoder().encode(Turn(role: "user", text: "hello"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json, ["role": "user", "text": "hello"])
    }

    func testDecodesOptionalActionsAndFutureEvents() throws {
        let data = Data(#"{"spoken":"Done","phone":{"action":"call_number","number":"+1234"},"timer":{"seconds":60,"label":"Tea"}}"#.utf8)
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        XCTAssertEqual(answer.phone?.number, "+1234")
        XCTAssertEqual(answer.timer?.seconds, 60)
        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(#"{"type":"future_event","new_field":true}"#.utf8))
        XCTAssertEqual(event.type, "future_event")
    }
}
