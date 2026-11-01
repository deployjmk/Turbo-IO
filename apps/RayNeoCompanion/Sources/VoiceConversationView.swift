import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var timeline: ConversationTimeline
    @State private var showKeys = false
    @State private var showConfiguration = false
    @State private var showSimulation = false
    @State private var showDiagnostics = false
    @State private var useCloud = true
    @State private var continuous = true
    @State private var confirmStart = false
    var body: some View {
        Screen(title: "Voice Session", eyebrow: "Cloud segmentation · streaming conversation") {
            HStack {
                Label(runtime.phaseLabel, systemImage: runtime.enabled ? "waveform" : "moon")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(); Badge(text: runtime.supportsDevice ? (runtime.ready ? "Authenticated" : "Not connected") : "Simulator preview")
            }.foregroundStyle(Palette.ink).padding(16).background(Palette.mint.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 18) {
                Label("What you say", systemImage: "mic").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.transcript.isEmpty ? "After wake-up, recognized text appears here" : runtime.transcript)
                    .font(.system(size: 18)).foregroundStyle(.white).privacySensitive()
                Divider().overlay(Palette.mint.opacity(0.3))
                Label("DeepSeek Flash", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.answer.isEmpty ? "The answer streams in word by word; you can interrupt by speaking" : runtime.answer)
                    .font(.system(size: 16)).foregroundStyle(Palette.mint).lineSpacing(6).privacySensitive()
                if runtime.modelComplete { Text("Model output complete · does not mean the lens has rendered it").font(.caption2).foregroundStyle(Palette.mint.opacity(0.6)) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("live-voice-content")
            if !runtime.enabled {
                Text("Microphone not enabled · no audio is being transmitted").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text(runtime.phase == "idle" || runtime.phase == "waitingForConnection" ? "Standing by — not all-day recording; waiting for the glasses to wake it up." : "This round of audio is still processing; turning off standby stops this round and any further automatic responses.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            HStack {
                Button("Model Settings") { if runtime.supportsDevice { showKeys = true } else { showConfiguration = true } }.accessibilityIdentifier("model-settings")
                Spacer()
                Button("Local Flow Demo") { showSimulation = true }.accessibilityIdentifier("open-session-lab")
            }.font(.subheadline)
            NavigationLink { CodexCompanionView() } label: {
                Label("Codex Tasks & Approvals", systemImage: "terminal")
            }.accessibilityIdentifier("codex-conversation-entry")
            NavigationLink { ModelToolsView() } label: {
                Label("AI Tools · See tools available to the model", systemImage: "wrench.and.screwdriver")
            }.accessibilityIdentifier("model-tools-conversation-entry")
            if let error = timeline.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber)
            }
            NavigationLink { ConversationTimelineView() } label: {
                Card { FeatureRow(icon: "clock.arrow.circlepath", title: "Conversation Timeline", subtitle: "Automatically logs conversations on this device · export and share", status: "Stored locally", active: true) }
            }.buttonStyle(.plain).accessibilityIdentifier("conversation-timeline")
            Card {
                Text("Voice stacks verified end to end").font(.headline).foregroundStyle(Palette.ink)
                FeatureRow(icon: "waveform", title: "Alibaba Cloud streaming ASR", subtitle: "Cloud VAD segmentation, no local silence trimming on top", status: "Prototype verified")
                Divider().overlay(Palette.line)
                FeatureRow(icon: "bolt", title: "DeepSeek V4 Flash", subtitle: "Thinking disabled · streamed text · no web search by default", status: "Prototype verified")
                Divider().overlay(Palette.line)
                Text("Continuous ASR stays on within the wake-up session; only a valid new sentence from the cloud interrupts the previous answer, and empty sentences never do. A 120-second guardrail applies per session. Codex tools need separate configuration and approval; there is no TTS yet.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if runtime.supportsDevice {
                Card {
                    Toggle("Use real cloud conversation", isOn: $useCloud).disabled(runtime.enabled)
                    Toggle("Continuous ASR · allow barge-in", isOn: $continuous).disabled(runtime.enabled || !useCloud).accessibilityIdentifier("voice-continuous-draft")
                    Text(runtime.enabled ? (runtime.cloud && runtime.continuous ? "Running live: continuous ASR · a valid newly recognized sentence interrupts" : "Running live: non-continuous mode · barge-in is not guaranteed during output") : "The toggles above are next-launch configuration; nothing is running yet")
                        .font(.caption).foregroundStyle(Palette.amber).accessibilityIdentifier("voice-effective-policy")
                    Text(useCloud ? "After wake-up, audio goes to your configured Alibaba Cloud ASR and the recognized text goes to DeepSeek; billing may apply." : "On-device WebRTC VAD only; each round replies with a random test string — nothing is recognized or uploaded.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Button(runtime.hasCredentials ? "Manage voice service keys" : "Set up ASR and model keys") { showKeys = true }
                        .disabled(runtime.enabled)
                }
                if runtime.enabled {
                    PrimaryButton(title: "Turn Off Standby", icon: "stop.circle") { runtime.stop() }
                    Button("End this round, keep standby") { runtime.endRound() }
                } else {
                    PrimaryButton(title: "Start Glasses Voice Standby", icon: "waveform", enabled: runtime.ready && (!useCloud || runtime.hasCredentials)) { confirmStart = true }
                }
                Button("Connection & Unbinding") { showDiagnostics = true }
                Text(runtime.latestEvent).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            } else {
                Text("This build loads no glasses communication library and calls no cloud services. On device, use the RayNeoCompanionDevice build; the demo below does not reflect real audio capture.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Text("After every answer chunk and the completion message are submitted, 10 seconds without a valid new sentence exits automatically; speaking again cancels the old timer. The timer does not start at the first character, and a submitted completion does not mean the lens has rendered the answer.")
                .font(.caption).foregroundStyle(Palette.amber)
            Button("Clear on-screen text") { runtime.clearText() }.font(.caption)
        }
        .onAppear { runtime.prepare(); reflectRunningPolicy() }
        .onChange(of: runtime.enabled) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.cloud) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.continuous) { _ in reflectRunningPolicy() }
        .sheet(isPresented: $showConfiguration) { ModelConfigurationView() }
        .sheet(isPresented: $showSimulation) { SessionSimulationView() }
        .sheet(isPresented: $showKeys) { LiveVoiceKeysView() }
        #if COMPANION_DEVICE
        .sheet(isPresented: $showDiagnostics, onDismiss: { runtime.refresh() }) {
            NavigationStack { VoiceDiagnosticsView(runtime: runtime).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } } }
        }
        #endif
        .confirmationDialog(useCloud ? "Once on, active wake-ups send audio to Alibaba Cloud and text to DeepSeek; the services may bill." : "Runs a local random-reply test; no voice is uploaded.", isPresented: $confirmStart) {
            Button("Confirm Standby On") { runtime.start(cloud: useCloud, continuous: continuous) }
        }
        .alert("Voice Services", isPresented: Binding(get: { runtime.error != nil }, set: { if !$0 { runtime.error = nil } })) {
            Button("Got it", role: .cancel) {}
        } message: { Text(runtime.error ?? "") }
    }
    private func reflectRunningPolicy() {
        guard runtime.enabled else { return }
        useCloud = runtime.cloud; continuous = runtime.continuous
    }
}

struct LiveVoiceKeysView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var asr = ""
    @State private var host = CloudASRHostSettings.current()
    @State private var llm = ""
    @State private var enableDefault = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Verified service combination") {
                    Text("Alibaba Cloud qwen-audio-3.0-asr-flash-streaming\nDeepSeek V4 Flash · thinking disabled · streaming")
                    Text("Enter your own Alibaba Cloud ASR host; the service must support this model and the DashScope streaming task protocol. DeepSeek uses its official fixed endpoint; other model settings pages remain drafts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("This app's dedicated keychain") {
                    TextField("Your ASR host (without https://)", text: $host)
                        .accessibilityIdentifier("live-asr-host").keyboardType(.URL)
                    Text("Changing the host does not reuse keys from another host. The source code contains neither the developer's tenant address nor keys.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Alibaba Cloud API Key (leave blank to keep)", text: $asr)
                        .accessibilityIdentifier("live-asr-key")
                    SecureField("DeepSeek API Key (leave blank to keep)", text: $llm)
                        .accessibilityIdentifier("live-llm-key")
                    Text("Keys from the official or test apps are never read. After first unlock they serve on-device background voice only — never synced, and the original values are never shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }.textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Toggle("After saving, default to cloud conversation and continuous barge-in", isOn: $enableDefault).accessibilityIdentifier("live-default-voice")
                Text("Default standby only waits for wake-up after connecting — it is not continuous recording. Standby turned off manually will not restart on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(enableDefault ? "Save and enable default standby" : "Save keys only, don't start conversation") {
                    let saved = runtime.saveKeys(asr: asr, llm: llm, host: host, enableDefault: enableDefault)
                    asr = ""; llm = ""
                    if saved { dismiss() }
                }.accessibilityIdentifier("live-save-keys")
                if let error = runtime.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.navigationTitle("Voice Service Keys").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
