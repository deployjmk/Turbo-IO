import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var automaticWeather: AutomaticWeather
    @EnvironmentObject private var qweather: QWeatherDashboard
    @State private var showSettings = false
    @State private var showConnection = false

    var body: some View {
        Screen(title: "My Glasses", eyebrow: "Turbo IO · Your local smart-glasses assistant", headerIcon: "gearshape", headerAction: { showSettings = true }) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("RayNeo iO").font(.system(size: 25, weight: .semibold))
                    Spacer()
                    if store.demoMode { Badge(text: "Demo UI", active: true) }
                }
                Text(runtime.ready ? "Authenticated connection" : "Not connected yet").font(.system(size: 15, weight: .medium))
                GlassesIllustration().padding(.horizontal, 15).padding(.vertical, 28)
                Text("Glasses outline illustration · not live device status").font(.system(size: 9)).foregroundStyle(Palette.mint.opacity(0.5))
            }
            .padding(22).foregroundStyle(.white)
            .background(LinearGradient(colors: [Palette.ink, Color(red: 0.10, green: 0.24, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))

            if runtime.supportsDevice {
                PrimaryButton(title: "Discover pairing glasses", icon: "antenna.radiowaves.left.and.right", enabled: !runtime.enabled) { runtime.discover() }
                Button("Connect the only discovered glasses") { runtime.connect() }.disabled(runtime.enabled)
                Button("Reconnect glasses already bonded to this app") { runtime.reconnectBonded() }
                    .accessibilityIdentifier("reconnect-bonded")
                Text(runtime.latestEvent).font(.caption).foregroundStyle(Palette.muted)
            } else {
                PrimaryButton(title: "Simulator does not connect to glasses", icon: "link", enabled: false) {}
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Button { store.selectedTab = 1 } label: { shortcut("mic", title: "Voice Assistant", subtitle: "Speech recognition and conversation") }.buttonStyle(.plain)
                Button { store.selectedTab = 2 } label: { shortcut("folder", title: "Recording Archive", subtitle: "Manage local audio") }.buttonStyle(.plain)
                NavigationLink { PrompterView() } label: { shortcut("text.alignleft", title: "Teleprompter", subtitle: "Edit and preview on the phone") }.buttonStyle(.plain)
                NavigationLink { TodoView() } label: { shortcut("checkmark.circle", title: "Todo List", subtitle: "Capture and manage tasks") }.buttonStyle(.plain)
            }
            NavigationLink { QWeatherDashboardView() } label: {
                Label(qweather.status, systemImage: "cloud.sun")
                    .font(.caption).foregroundStyle(Palette.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("device-weather-status")
            Button { showConnection = true } label: {
                Label("Local features available; glasses control still to be verified", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.green).padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { runtime.prepare() }
        .sheet(isPresented: $showConnection) { ConnectionBoundaryView() }
    }

    private func shortcut(_ icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 25, weight: .light)).foregroundStyle(Palette.ink)
                .frame(width: 34, height: 38).background(Palette.mint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.line.opacity(0.6), lineWidth: 0.75))
    }
}

struct ConnectionBoundaryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "link.badge.plus").font(.system(size: 35, weight: .light)).foregroundStyle(Palette.green)
                    Text("Connection, with clear boundaries.").font(.title2.bold()).foregroundStyle(Palette.ink)
                    Text("Turbo IO uses its own bundle and sandbox. The device build is wired to the prototype communication core and voice pipeline; the simulator build loads no vendor library and sends no Bluetooth commands. Pairing, background behavior, and lens effects for the new app still need re-verification on real hardware.")
                        .font(.subheadline).foregroundStyle(Palette.muted).lineSpacing(5)
                    Card {
                        FeatureRow(icon: "iphone", title: "On-phone local features", subtitle: "Drafts, imports, configuration, and status demos", status: "Available", active: true)
                        FeatureRow(icon: "link", title: "Connection, authentication, and unbinding", subtitle: "Reuses the prototype core on device; never unbinds or resets automatically")
                        FeatureRow(icon: "eyeglasses", title: "Lens display and reverse events", subtitle: "Must be accepted item by item on the actual glasses")
                        FeatureRow(icon: "signature", title: "Non-jailbroken signed device", subtitle: "The simulator build does not prove the non-jailbroken path", status: "On-device pending")
                    }
                    Text("It will not touch firmware, unbind the official account, turn the microphone on automatically, or upload recordings.")
                        .font(.footnote).foregroundStyle(Palette.green)
                }.padding(24)
            }.background(Palette.background).navigationTitle("Connection Progress").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
