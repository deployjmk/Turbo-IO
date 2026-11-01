import SwiftUI

// Settings + status surface for the homelab uplink (v0.1).
// Endpoint is a UserDefaults draft; the bearer token goes to the Keychain only.
struct HermesUplinkView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var endpointDraft = ""
    @State private var tokenDraft = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section("Homelab Uplink") {
                LabeledContent("State") {
                    Text(store.uplink.stateLabel).font(.footnote).foregroundStyle(secondary)
                }
                LabeledContent("Endpoint") { Text(store.uplink.endpoint.isEmpty ? "not set" : store.uplink.endpoint).font(.footnote) }
                LabeledContent("Token") { Text(store.uplink.tokenConfigured ? "saved in Keychain" : "not set").font(.footnote) }
                LabeledContent("Live mode") { Text(store.uplink.liveMode ? "active" : "off").font(.footnote) }
            }
            Section("Connect") {
                TextField("wss://glasses.3lc.hk/ws or ws://192.168.1.23:8080", text: $endpointDraft)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Bearer token (stored in Keychain)", text: $tokenDraft)
                HStack {
                    Button("Save endpoint") {
                        if store.uplink.saveEndpoint(endpointDraft) { message = "Endpoint saved." } else { message = "Invalid endpoint." }
                    }
                    Button("Save token") {
                        if store.uplink.saveToken(tokenDraft) { tokenDraft = ""; message = "Token saved to Keychain." } else { message = "Token must be 1-512 chars, no spaces." }
                    }
                }
                HStack {
                    Button("Connect") { store.uplink.enterLive(); refreshDraft() }
                    Button("Disconnect") { store.uplink.exitLive(); refreshDraft() }
                }
                Button("Send status now") {
                    store.uplink.sendHello(deviceID: store.voice.deviceID ?? "unpaired", appVersion: "v0.1")
                    message = "Hello + status queued (only sent while connected)."
                }
            }
            Section {
                Text(store.uplink.status).font(.footnote)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Live mode is battery-friendly: the socket stays open only during an active teleprompter or capture session; otherwise it reconnects on next foreground. Set the endpoint to ws://192.168.1.23:<port> for LAN development.")
            }
        }
        .navigationTitle("Homelab Uplink")
        .onAppear { refreshDraft() }
    }

    private var secondary: Color { store.uplink.state == .connected ? .green : .secondary }

    private func refreshDraft() { endpointDraft = store.uplink.endpoint }
}

private extension UplinkState {
    var stateLabel: String {
        switch self {
        case .disabled: return "disabled"
        case .idle: return "idle"
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
