import Foundation
import Combine
import Security

// HermesUplink: WebSocket client the companion app maintains to Jordan's homelab
// Hermes agent. Protocol is documented in docs/UPLINK.md. Design goals:
//  - Battery-friendly: the connection is a foreground "live mode" feature, not a
//    background service. Outside an active teleprompter/capture session the app
//    may disconnect and simply reconnect on next foreground.
//  - No secrets in UserDefaults: the bearer token lives in the Keychain.
//  - Pure-logic pieces (wire decoding, endpoint canonicalization, backoff) are
//    static/free functions so they are unit-testable on any platform.

enum UplinkWire {
    // Homelab -> app
    struct PushTeleprompter: Equatable {
        var text: String
        var speed: Int
        var append: Bool
    }
    enum TeleprompterAction: String, Equatable {
        case pause, resume, stop
        var controlType: UInt32 {
            switch self { case .pause: return 4; case .resume: return 5; case .stop: return 6 }
        }
    }
    enum Inbound {
        case pushTeleprompter(PushTeleprompter)
        case teleprompterControl(TeleprompterAction)
        case ping(ts: Double)
        case configUpdate([String: Any])
        case unknown(type: String)
    }

    static let maxMessageBytes = 262_144
    static let maxTeleprompterText = 12_000
    static let speedRange = 60...240

    /// Decode one inbound JSON message. Returns nil for malformed/oversized frames.
    static func decode(_ data: Data) -> Inbound? {
        guard data.count <= maxMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "push_teleprompter":
            guard let text = object["text"] as? String, !text.isEmpty,
                  text.count <= maxTeleprompterText, text.utf8.count <= 48_000 else { return nil }
            let mode = (object["mode"] as? String) ?? "replace"
            guard ["replace", "append"].contains(mode) else { return nil }
            var speed = 120
            if let raw = object["speed"] as? Int, speedRange.contains(raw) { speed = raw }
            return .pushTeleprompter(PushTeleprompter(text: text, speed: speed, append: mode == "append"))
        case "teleprompter_control":
            guard let action = TeleprompterAction(rawValue: object["action"] as? String ?? "") else { return nil }
            return .teleprompterControl(action)
        case "ping":
            return .ping(ts: (object["ts"] as? Double) ?? (object["ts"] as? Int).map(Double.init) ?? 0)
        case "config_update":
            return .configUpdate(object["config"] as? [String: Any] ?? [:])
        default:
            return .unknown(type: String(type.prefix(64)))
        }
    }

    // App -> homelab
    static func hello(deviceID: String, appVersion: String) -> [String: Any] {
        ["type": "hello", "deviceId": deviceID, "appVersion": appVersion, "protocol": 1]
    }
    static func status(connected: Bool, battery: Int?) -> [String: Any] {
        var body: [String: Any] = ["type": "status", "glassesConnected": connected]
        if let battery, (0...100).contains(battery) { body["battery"] = battery }
        return body
    }
    static func transcript(_ text: String, sessionID: String, final: Bool) -> [String: Any] {
        ["type": "transcript", "sessionID": sessionID, "text": String(text.prefix(4000)), "final": final]
    }
    static let heartbeat: [String: Any] = ["type": "heartbeat"]
    static func pong(ts: Double) -> [String: Any] { ["type": "pong", "ts": ts] }
}

struct UplinkEndpoint {
    /// Normalizes a user-entered endpoint:
    ///  - accepts ws://, wss://, and LAN http(s):// (mapped to ws/wss for the socket)
    ///  - rejects credentials/query/fragment, whitespace, empty host
    ///  - drops default ports; keeps explicit non-default ports
    static func canonicalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var url = URLComponents(string: trimmed), !trimmed.contains(" ") else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["ws", "wss", "http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        url.scheme = ["ws", "http"].contains(scheme) ? "ws" : "wss"
        url.host = host.lowercased()
        if url.port == (url.scheme == "ws" ? 80 : 443) { url.port = nil }
        url.path = url.path.isEmpty ? "/" : url.path
        return url.string
    }

    /// Default for Jordan's homelab: change via settings; LAN dev uses ws://192.168.1.23:PORT
    static let suggested = "wss://glasses.3lc.hk/ws"
}

/// Exponential reconnect backoff, capped. Attempt 0 is the first retry.
enum UplinkBackoff {
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        let base = min(attempt, 6) // 1,2,4,8,16,32,60 (cap)
        let seconds = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0][base]
        return min(seconds, 60)
    }
    static let maxAttempts = 8
}

enum UplinkState: Equatable {
    case disabled, idle, connecting, connected, failed(String)
}

/// ObservableObject wrapper over URLSessionWebSocketTask.
/// All state mutations happen on the main actor; socket callbacks hop via the
/// internal delegate relay.
@MainActor
final class HermesUplink: ObservableObject {
    @Published private(set) var state: UplinkState = .idle
    @Published private(set) var status = "Uplink not configured."
    @Published private(set) var liveMode = false
    @Published private(set) var lastInbound: UplinkWire.Inbound?
    @Published var endpoint: String

    var onPushTeleprompter: ((UplinkWire.PushTeleprompter) -> Void)?
    var onTeleprompterControl: ((UplinkWire.TeleprompterAction) -> Void)?
    var onConfigUpdate: (([String: Any]) -> Void)?
    var deviceStatus: () -> (connected: Bool, battery: Int?) = { (false, nil) }
    var deviceID: () -> String = { UIDPlaceholder.id }
    var appVersion: () -> String = { "v0.1" }
    var retainedSubscriptions: [AnyCancellable] = []

    static let endpointKey = "hermesUplink.v1.endpoint"
    private static let tokenService = "io.turboio.companion.uplink"
    private static let tokenAccount = "bearer-token"
    private let defaults: UserDefaults
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var relay: SocketRelay?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var liveDeadline: Date?
    private var explicitClose = false
    private var didHello = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: Self.endpointKey) ?? ""
    }

    // MARK: Configuration

    func saveEndpoint(_ raw: String) -> Bool {
        guard let value = UplinkEndpoint.canonicalize(raw) else {
            status = "Invalid endpoint. Use ws://, wss:// or LAN http(s):// with no credentials."
            return false
        }
        endpoint = value
        defaults.set(value, forKey: Self.endpointKey)
        status = "Endpoint saved: \(value)"
        return true
    }

    func saveToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 512, !token.contains(where: { $0.isWhitespace }) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService, kSecAttrAccount as String: Self.tokenAccount]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }

    var tokenConfigured: Bool { Self.loadToken() != nil }

    private static func loadToken() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService, kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var configured: Bool { !endpoint.isEmpty && tokenConfigured }

    // MARK: Live mode (battery-friendly gating)

    /// Live mode is only active during an actual session: an active teleprompter
    /// or capture. Outside sessions the socket is closed and re-established on
    /// the next foreground/enterLive.
    func enterLive(seconds: TimeInterval = 300) {
        liveDeadline = Date().addingTimeInterval(seconds)
        if !liveMode { liveMode = true }
        if configured, case .connected = state {} else { connect(reason: "live session") }
    }
    func exitLive() {
        liveMode = false; liveDeadline = nil
        disconnect(reason: "session ended")
    }
    /// Called when the app becomes active again; reconnects if a session is live.
    func foreground() {
        guard liveMode, configured else { return }
        if case .connected = state {} else { connect(reason: "foreground") }
    }

    // MARK: Connection

    func connect(reason: String) {
        guard configured else { status = "Uplink not configured. Set endpoint and token first."; return }
        guard task == nil else { return }
        explicitClose = false
        guard let address = UplinkEndpoint.canonicalize(endpoint), let url = URL(string: address) else {
            state = .failed("invalid endpoint"); status = "Invalid endpoint."; return
        }
        state = .connecting
        status = "Connecting to \(address) (\(reason))…"
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session
        let newRelay = SocketRelay()
        relay = newRelay
        newRelay.owner = self
        var request = URLRequest(url: url)
        if let token = Self.loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let webSocketTask = session.webSocketTask(with: request)
        task = webSocketTask
        webSocketTask.delegate = newRelay
        webSocketTask.resume()
        receiveLoop(on: webSocketTask)
        startHeartbeat()
    }

    func disconnect(reason: String) {
        explicitClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; relay = nil
        session?.invalidateAndCancel(); session = nil
        reconnectAttempt = 0; didHello = false
        if !liveMode {
            state = .idle
            status = "Disconnected (\(reason)). Reconnects on next session or foreground."
        }
    }

    private func receiveLoop(on webSocketTask: URLSessionWebSocketTask) {
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === webSocketTask else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop(on: webSocketTask)
                case .failure:
                    self.connectionLost()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let inbound = UplinkWire.decode(data) else { return }
        lastInbound = inbound
        switch inbound {
        case .pushTeleprompter(let push):
            enterLive() // an inbound push means a session is active
            onPushTeleprompter?(push)
            status = "Teleprompter push received (\(push.append ? "append" : "replace"), \(push.text.count) chars)."
        case .teleprompterControl(let action):
            enterLive()
            onTeleprompterControl?(action)
            status = "Teleprompter control: \(action.rawValue)."
        case .ping(let ts):
            send(UplinkWire.pong(ts: ts))
        case .configUpdate(let config):
            onConfigUpdate?(config)
            status = "Config update received."
        case .unknown(let type):
            status = "Ignored unknown message type: \(type)."
        }
    }

    func send(_ json: [String: Any]) {
        guard let task, case .connected = state else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, error != nil else { return }
                self.connectionLost()
            }
        }
    }

    func sendHello(deviceID: String, appVersion: String) {
        send(UplinkWire.hello(deviceID: deviceID, appVersion: appVersion))
        let (connected, battery) = deviceStatus()
        send(UplinkWire.status(connected: connected, battery: battery))
    }

    func sendTranscript(_ text: String, sessionID: String, final: Bool) {
        guard liveMode else { return } // transcripts only flow during live sessions
        send(UplinkWire.transcript(text, sessionID: sessionID, final: final))
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .connected = self.state else { return }
                self.send(UplinkWire.heartbeat)
                if let deadline = self.liveDeadline, deadline < Date() { self.exitLive(); return }
            }
        }
    }

    private func connectionLost() {
        guard !explicitClose else { return }
        task = nil; relay = nil
        session?.invalidateAndCancel(); session = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        didHello = false
        guard liveMode else { state = .idle; status = "Connection lost. Reconnects on next session."; return }
        guard reconnectAttempt < UplinkBackoff.maxAttempts else {
            state = .failed("reconnect exhausted")
            status = "Gave up after \(UplinkBackoff.maxAttempts) reconnect attempts."
            return
        }
        let delay = UplinkBackoff.delay(afterAttempt: reconnectAttempt)
        reconnectAttempt += 1
        state = .connecting
        status = "Reconnecting in \(Int(delay))s (attempt \(reconnectAttempt))."
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.liveMode, !self.explicitClose else { return }
            self.connect(reason: "reconnect")
        }
    }

    // Called by the relay when the OS-level open completes (success or error).
    fileprivate func socketOpened(_ webSocketTask: URLSessionWebSocketTask?, error: Error?) {
        guard !explicitClose, task === webSocketTask else { return }
        if let error {
            status = "Socket open failed: \(error.localizedDescription)"
            connectionLost()
            return
        }
        state = .connected
        reconnectAttempt = 0
        status = "Connected to \(endpoint)."
        sendHello(deviceID: deviceID(), appVersion: appVersion())
    }
}

// URLSessionWebSocketDelegate cannot be an @MainActor class; this tiny relay
// forwards open/close events to the main actor.
final class SocketRelay: NSObject, URLSessionWebSocketDelegate {
    weak var owner: HermesUplink? // main-actor object; hops via Task { @MainActor }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let task = webSocketTask
        Task { @MainActor [weak owner] in owner?.socketOpened(task, error: nil) }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak owner] in owner?.connectionLostPublic() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Open failures surface here too; ignore clean cancels we initiated.
        guard let error else { return }
        let socketTask = task as? URLSessionWebSocketTask
        Task { @MainActor [weak owner] in owner?.socketOpened(socketTask, error: error) }
    }
}

@MainActor
extension HermesUplink {
    func connectionLostPublic() { connectionLost() }
}

// Avoid a UIKit import in this file; the store supplies the real device id.
enum UIDPlaceholder { static let id = "unspecified" }
