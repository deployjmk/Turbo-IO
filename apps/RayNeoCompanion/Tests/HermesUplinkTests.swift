import XCTest
@testable import RayNeoCompanion

final class HermesUplinkTests: XCTestCase {
    func testDecodePushTeleprompter() throws {
        let data = Data(#"{"type":"push_teleprompter","text":"hello coach","mode":"append","speed":90}"#.utf8)
        guard case .pushTeleprompter(let push) = UplinkWire.decode(data) else { return XCTFail("expected push") }
        XCTAssertEqual(push.text, "hello coach")
        XCTAssertEqual(push.speed, 90)
        XCTAssertTrue(push.append)
    }

    func testDecodeDefaultsToReplaceAndDefaultSpeed() throws {
        let data = Data(#"{"type":"push_teleprompter","text":"script"}"#.utf8)
        guard case .pushTeleprompter(let push) = UplinkWire.decode(data) else { return XCTFail("expected push") }
        XCTAssertFalse(push.append)
        XCTAssertEqual(push.speed, 120)
    }

    func testDecodeRejectsBadPushes() {
        XCTAssertNil(UplinkWire.decode(Data(#"{"type":"push_teleprompter","text":""}"#.utf8)))
        XCTAssertNil(UplinkWire.decode(Data(#"{"type":"push_teleprompter","text":"x","mode":"bogus"}"#.utf8)))
        XCTAssertNil(UplinkWire.decode(Data(#"{"type":"push_teleprompter","text":"x","speed":12}"#.utf8)))
        XCTAssertNil(UplinkWire.decode(Data("not json".utf8)))
        XCTAssertNil(UplinkWire.decode(Data(#"{"type":"push_teleprompter"}"#.utf8)))
    }

    func testDecodeControlAndPing() throws {
        guard case .teleprompterControl(let pause) = UplinkWire.decode(Data(#"{"type":"teleprompter_control","action":"pause"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(pause, .pause)
        XCTAssertEqual(pause.controlType, 4)
        guard case .teleprompterControl(let stop) = UplinkWire.decode(Data(#"{"type":"teleprompter_control","action":"stop"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(stop.controlType, 6)
        XCTAssertNil(UplinkWire.decode(Data(#"{"type":"teleprompter_control","action":"rewind"}"#.utf8)))
        guard case .ping(let ts) = UplinkWire.decode(Data(#"{"type":"ping","ts":123}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(ts, 123)
        guard case .unknown(let type) = UplinkWire.decode(Data(#"{"type":"mystery"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(type, "mystery")
    }

    func testEncodeOutboundMessages() throws {
        let hello = UplinkWire.hello(deviceID: "d1", appVersion: "v0.1")
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["deviceId"] as? String, "d1")
        let status = UplinkWire.status(connected: true, battery: 77)
        XCTAssertEqual(status["battery"] as? Int, 77)
        XCTAssertNil(UplinkWire.status(connected: true, battery: 200)["battery"])
        let transcript = UplinkWire.transcript("note", sessionID: "s1", final: false)
        XCTAssertEqual(transcript["final"] as? Bool, false)
    }

    func testEndpointCanonicalization() {
        XCTAssertEqual(UplinkEndpoint.canonicalize("wss://glasses.3lc.hk/ws"), "wss://glasses.3lc.hk/ws")
        XCTAssertEqual(UplinkEndpoint.canonicalize("HTTPS://Glasses.Example.COM"), "wss://glasses.example.com/")
        XCTAssertEqual(UplinkEndpoint.canonicalize("http://192.168.1.23:8080"), "ws://192.168.1.23:8080/")
        XCTAssertEqual(UplinkEndpoint.canonicalize("wss://host:443"), "wss://host/")
        XCTAssertEqual(UplinkEndpoint.canonicalize("ws://host:80"), "ws://host/")
        XCTAssertNil(UplinkEndpoint.canonicalize("https://user:pass@host/ws"))
        XCTAssertNil(UplinkEndpoint.canonicalize("wss://host/ws?token=1"))
        XCTAssertNil(UplinkEndpoint.canonicalize("ftp://host"))
        XCTAssertNil(UplinkEndpoint.canonicalize("   "))
    }

    func testBackoffIsExponentialAndCapped() {
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 0), 1)
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 1), 2)
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 3), 8)
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 5), 32)
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 6), 60)
        XCTAssertEqual(UplinkBackoff.delay(afterAttempt: 20), 60)
    }
}

final class CloudLLMEndpointSettingsTests: XCTestCase {
    func testDefaultsMatchFormerHardcodedDeepSeek() throws {
        let suite = "turboio-llm-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = CloudLLMEndpointSettings.current
        XCTAssertFalse(endpoint.model.isEmpty)
        XCTAssertTrue(endpoint.baseURL.hasPrefix("http"))
        _ = defaults
    }

    func testNormalizeAcceptsHTTPAndHTTPSAndStripsTrailingSlash() {
        XCTAssertEqual(CloudLLMEndpointSettings.normalize(" http://100.77.205.126:8648/v1/ "), "http://100.77.205.126:8648/v1")
        XCTAssertEqual(CloudLLMEndpointSettings.normalize("https://api.deepseek.com"), "https://api.deepseek.com")
        XCTAssertEqual(CloudLLMEndpointSettings.normalize("https://Host.Example:443"), "https://host.example")
        XCTAssertNil(CloudLLMEndpointSettings.normalize("https://u:p@host/v1"))
        XCTAssertNil(CloudLLMEndpointSettings.normalize("wss://host"))
        XCTAssertNil(CloudLLMEndpointSettings.normalize(""))
        XCTAssertNil(CloudLLMEndpointSettings.normalize(nil))
    }

    func testChatCompletionsJoinAndDeepSeekFlag() {
        let hermes = CloudLLMEndpointSettings.Endpoint(baseURL: "http://100.77.205.126:8648/v1", model: "hermes-agent")
        XCTAssertEqual(hermes.chatCompletionsURL, "http://100.77.205.126:8648/v1/chat/completions")
        XCTAssertFalse(hermes.isDeepSeek)
        let deepseek = CloudLLMEndpointSettings.Endpoint(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash")
        XCTAssertTrue(deepseek.isDeepSeek)
    }
}
