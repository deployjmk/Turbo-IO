# BUILD.md — Building the fork on a Mac (Jordan's MacBook Air, arm64)

These are the exact steps to build and run `RayNeoCompanionDevice` (the build
that actually talks to the RayNeo iO glasses) from this fork on a physical
iPhone with Jordan's paid Apple Developer account.

## 1. Tools (one-time)

```bash
# Xcode 27.0+ (App Store or xcodes), then accept license + install iOS platform
xcodebuild -version

brew install xcodegen          # project generator (project-device.yml)
brew install node              # needed by scripts/start.mjs preflight
```

Swift 6.2+ toolchain comes with current Xcode (the transport package wants it).

## 2. Generate the project and open it

```bash
git clone https://github.com/deployjmk/Turbo-IO.git   # this fork
cd Turbo-IO
git checkout live-coach-v01
node scripts/start.mjs --device        # preflights all vendored dependencies
cd apps/RayNeoCompanion && xcodegen generate && open RayNeoCompanion.xcodeproj
```

All dependencies (RayneoNet.framework + 6 supporting frameworks, libopus.a,
webrtcvad C sources, ZIPFoundation) are vendored in-repo and SHA-256-pinned in
`DEPENDENCIES.json` — no network fetches.

## 3. Select target + signing

1. In Xcode select the **RayNeoCompanionDevice** scheme (NOT plain
   `RayNeoCompanion` — that target has no glasses transport at all).
2. Target `RayNeoCompanionDevice` → Signing & Capabilities → check
   "Automatically manage signing", Team = Jordan's paid team. Bundle id is
   `io.turboio.companion` (change it if you want, but that resets Keychain/data
   isolation vs. any prior install).
3. Plug in the iPhone, select it as the run destination, Trust the computer.

## 4. Run on the device

- Product ▸ Run. First launch: Settings ▸ General ▸ VPN & Device Management →
  trust the developer certificate if prompted.
- **Before first pairing**: unbind the glasses in the official RayNeo app AND
  "Forget this device" in iOS Bluetooth settings (see README/CONFIGURATION.md).
  One client at a time; reconnect policy is single-bond.

## 5. Point the uplink at LAN for dev

In the app: Tools ▸ **Homelab Uplink**:

- Endpoint: `ws://192.168.1.23:<port>` (plain ws and LAN http(s) are accepted;
  production uses `wss://glasses.3lc.hk/ws`).
- Token: paste the homelab bearer token (stored in the iOS Keychain only).
- Tap Save endpoint, Save token, then Connect. `hello` + `status` are sent on
  connect; the homelab can then push `push_teleprompter` /
  `teleprompter_control` / `ping` / `config_update` — see docs/UPLINK.md.

## 6. LLM endpoint (voice answers)

Voice conversation ▸ settings: ASR stays DashScope for v0.1 (do not change the
ASR host yet). The LLM base URL + model are configurable
(`CloudLLMEndpointSettings`); for the homelab Hermes server set:

- Base URL: `http://100.77.205.126:8648/v1` (OpenAI-compatible)
- Model: `hermes-agent`
- Key: the Hermes API key (Keychain only)

## 7. Tests

```bash
# 214 app tests + 445 package tests must stay green
cd apps/RayNeoCompanion
xcodegen generate
xcodebuild test -project RayNeoCompanion.xcodeproj -scheme RayNeoCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 16'
# package tests:
for p in rayneo-protocol rayneo-display rayneo-session rayneo-archive rayneo-audio-container rayneo-transport-ios; do
  (cd ../../$p && swift test)
done
```

## 8. Unsigned CI artifact

GitHub Actions (`.github/workflows/build-device.yml`, macos-15) builds
`RayNeoCompanionDevice` with `CODE_SIGNING_ALLOWED=NO` and uploads an unsigned
IPA artifact. Download it, then sign locally:

```bash
# ad-hoc quick check, or with your team identity:
codesign --remove-signature Payload/RayNeoCompanion.app 2>/dev/null
codesign -s "Apple Development: <YOUR-ID>" --entitlements - \
  --options runtime Payload/RayNeoCompanion.app   # entitlements from Xcode export
xcrun altool --sign ... # or simply archive in Xcode for device install
```

Simplest path for personal use: build in Xcode directly (step 4) — CI artifacts
are mainly a compile-health check.

## Known pitfalls (from VALIDATION.md)

- Device target verified to *compile unsigned* from this source drop; real-device
  acceptance ≠ all-features acceptance.
- Recorder receive switch needs re-checking after app relaunch.
- Todo-completion sync back to the phone is a known unfixed upstream bug.
- Firmware: do NOT update glasses firmware blindly; pin the version that worked.
