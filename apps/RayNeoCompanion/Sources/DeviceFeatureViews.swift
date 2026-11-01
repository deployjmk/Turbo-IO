import SwiftUI

struct GlassesRecordingCard: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var confirmStart = false
    @State private var expanded = false
    var body: some View {
        Card {
            DisclosureGroup(isExpanded:$expanded) {
              VStack(alignment:.leading,spacing:12) {
                Text(features.recordingStatus).font(.caption).foregroundStyle(Palette.muted)
                if features.recordingBytes > 0 { Text("Received \(ByteCountFormatter.string(fromByteCount:Int64(features.recordingBytes),countStyle:.file))").font(.caption.monospacedDigit()) }
                Toggle("Let the glasses start recordings saved on this device",isOn:Binding(get:{features.acceptsEyeRecording},set:{features.enableEyeRecording($0)}))
                    .font(.caption).disabled(features.recordingID != nil || !voice.ready)
                if features.recordingID == nil {
                    Button("Start recording on the glasses") { confirmStart = true }.disabled(!voice.ready)
                } else {
                    HStack {
                        Button("Pause") { features.recordingControl(8) }
                        Button("Resume") { features.recordingControl(9) }
                        Button("Mark") { features.recordingControl(11) }
                        Button("Stop") { features.recordingControl(4) }
                    }.disabled(!voice.ready)
                }
                Text("Voice standby pauses during recording. Audio is saved only — no automatic ASR, upload, or deletion of glasses files; when it ends, re-enable standby from the Session tab. Importing the offline backlog is accepted separately.").font(.caption2).foregroundStyle(Palette.muted)
                if let file = features.completedRecording {
                    HStack { ShareLink(item:file) { Label("Share WAV",systemImage:"square.and.arrow.up") }; Button("Retry Archiving") { Task { await features.archiveReceivedRecording() } } }.font(.caption)
                } else if features.recordingID != nil {
                    Button("Re-verify after the completion message") { features.retryRecordingFinish() }.font(.caption)
                }
                if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
              }.padding(.top,12)
            } label: {
                VStack(alignment:.leading,spacing:6) {
                    Label("Glasses Recording",systemImage:"mic.badge.plus").font(.headline)
                    Text(features.recordingID == nil ? "Expand for recording controls · capture is off by default" : features.recordingStatus).font(.caption2).foregroundStyle(Palette.muted)
                }
            }.accessibilityIdentifier("recording-controls").padding(18)
            NavigationLink("Find locally received files from before the restart") { RecordingRecoveryView() }
                .font(.caption).padding(.horizontal,18).padding(.bottom,14).accessibilityIdentifier("recording-recovery")
        }
        .confirmationDialog("Start a glasses recording and save it to Turbo IO? AI voice standby will pause, and nothing is uploaded automatically.",isPresented:$confirmStart) {
            Button("Start Recording") { features.startRecording() }
        }
        .onAppear { features.prepare() }
        .onChange(of:features.recordingID) { if $0 != nil { expanded = true } }
    }
}

struct GlassesTodoSyncCard: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var confirm = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Button("Sync on-device todos to the glasses") { confirm = true }.disabled(!voice.ready)
            Text(features.todoStatus).font(.caption).foregroundStyle(Palette.muted)
            Text("The first sync requires confirmation; edits to already-linked items are sent when possible, and offline edits are kept for retry. Status conflicts never overwrite phone-side changes — see pending sends and conflict handling. Removing only affects this device and never deletes older glasses entries.").font(.caption2).foregroundStyle(Palette.muted)
            if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
        }
        .confirmationDialog("Send the on-device todos you haven't removed to the current glasses? Official tasks other than these are untouched.",isPresented:$confirm) {
            Button("Send On-Device Todos") { features.syncTodos() }
        }.onAppear { features.prepare() }
    }
}

struct GlassesPrompterControls: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    let text: String
    @State private var speed = 120.0
    @State private var confirm = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Glasses Teleprompter · Constant Speed").font(.headline)
            Text(features.teleprompterStatus).font(.caption).foregroundStyle(Palette.muted)
            HStack { Text("Scroll speed"); Spacer(); Text("\(Int(speed)) chars/min candidate").monospacedDigit() }.font(.caption)
            Slider(value:$speed,in:60...240,step:10)
            if features.teleprompterID == nil {
                Button("Prepare & Send Current Script") { confirm = true }.disabled(!voice.ready || text.isEmpty)
            } else {
                HStack {
                    Button("Start") { features.teleprompterControl(3) }
                    Button("Pause") { features.teleprompterControl(4) }
                    Button("Resume") { features.teleprompterControl(5) }
                    Button("Exit") { features.teleprompterControl(6) }
                }.disabled(!voice.ready)
                Button("Apply Scroll Speed") { features.teleprompterControl(7,speed:Int(speed)) }.disabled(!voice.ready)
            }
            Text("Only the current segment is sent (up to 12,000 characters), never the whole book. Starting is allowed only after the receipt confirmation; the glasses report raw progress, which is not pretended to equal phone pagination. Smart follow-along is not enabled.").font(.caption2).foregroundStyle(Palette.muted)
            if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
        }.padding(16).background(.white,in:RoundedRectangle(cornerRadius:16))
        .confirmationDialog("Send the current text to the glasses? AI standby pauses; the text travels only over the local connection.",isPresented:$confirm) {
            Button("Prepare Current Script") { features.prepareTeleprompter(text,speed:Int(speed)) }
        }.onAppear { features.prepare() }
    }
}

struct GlassesSettingsView: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var location = "Protocol Test City"
    @State private var temperature = 27
    @State private var icon = "100"
    @State private var description = "Custom test weather"
    @State private var confirmWeather = false
    var body: some View {
        Form {
            Section("Connection & Live Status") {
                Text(voice.ready ? "Authenticated connection" : "Not connected (the simulator sends no packets)")
                LabeledContent("Battery",value:features.battery.map { "\($0)%" } ?? "Not read yet")
                LabeledContent("Brightness",value:features.brightness.map(String.init) ?? "Not read yet")
                Button("Read Status & Settings from Glasses") { features.refreshSettings() }.disabled(!voice.ready)
                Text(features.status).font(.caption)
            }
            Section("Weather Services") {
                NavigationLink("Dashboard Live Weather · QWeather") { QWeatherDashboardView() }.accessibilityIdentifier("qweather-entry")
                NavigationLink("Legacy Weatherstack Manual Lookup") { WeatherstackView() }.accessibilityIdentifier("weatherstack-entry")
                Text("Dedicated key · manual lookup · sync after previewing. No location permission needed.").font(.caption)
            }
            Section("Verified Settings Controls") {
                HStack { Button("Brightness 7") { features.setBrightness(7) }; Spacer(); Button("Brightness 8") { features.setBrightness(8) } }
                HStack { Button("Sleep 15 s") { features.setSleep(15) }; Spacer(); Button("Sleep 25 s") { features.setSleep(25) } }
                Button("Head Control On · Mode 0") { features.setHeadControl(true,mode:0) }
                Button("Head Control Off") { features.setHeadControl(false,mode:0) }
                Button("Double-Tap Opens Todos") { features.setDoubleTapTodo(true) }
                Button("Double-Tap Returns to AI") { features.setDoubleTapTodo(false) }
                Button("Display Height Level 1") { features.setDisplay(height:1) }
                Button("Display Height Level 3") { features.setDisplay(height:3) }
                Button("Display Distance Level 1") { features.setDisplay(distance:1) }
                Button("Display Distance Level 2") { features.setDisplay(distance:2) }
                Text("Only the subset with evidence-backed value ranges is exposed; unknown privacy fields are never touched. A submitted button is not proof the glasses physically took effect.").font(.caption)
            }.disabled(!voice.ready)
            Section("Custom Weather · Not a Live Weather Service") {
                TextField("City label",text:$location)
                Stepper("Temperature \(temperature)",value:$temperature,in:-80...60)
                TextField("Firmware raw icon number",text:$icon).keyboardType(.numberPad)
                TextField("Weather text",text:$description)
                Button("Send Home-Screen Test Weather") { confirmWeather = true }.disabled(!voice.ready || Int(icon) == nil)
                Text("Only the content is sent; the existing dashboard layout stays. The home-screen mini weather and the city card are separate channels; the icon number and lens effect need on-device re-verification. There is currently no automatic location, online weather lookup, or background refresh.").font(.caption)
            }
            if let error = features.error { Section("Notice") { Text(error).foregroundStyle(Palette.amber) } }
        }.navigationTitle("Weather & Device Settings")
        .confirmationDialog("Send this clearly labeled test weather to the glasses?",isPresented:$confirmWeather) {
            Button("Send Custom Data") { features.sendWeather(location:location,temperature:temperature,icon:Int(icon) ?? 100,description:description) }
        }.onAppear { features.prepare() }
    }
}
