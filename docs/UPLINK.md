# Hermes Uplink Protocol (v0.1)

The companion app maintains a WebSocket connection ("uplink") to Jordan's homelab
Hermes agent so the homelab can push coach scripts to the RayNeo iO lens and
observe session status. This document is the v0.1 wire contract implemented by
`apps/RayNeoCompanion/Sources/HermesUplink.swift`.

## Transport

- WebSocket (RFC 6455) via `URLSessionWebSocketTask`.
- Endpoint is user-configurable: `wss://…` (production, e.g. `wss://glasses.3lc.hk/ws`),
  plain `ws://`, and LAN `http://` / `https://` URLs are accepted for development
  (http/https are mapped to ws/wss for the socket). Example LAN dev endpoint:
  `ws://192.168.1.23:8080`.
- Authentication: HTTP `Authorization: Bearer <token>` header on the upgrade
  request. The token is stored in the iOS Keychain
  (service `io.turboio.companion.uplink`, account `bearer-token`) — never in
  UserDefaults, never in code.
- Frames are single-line JSON objects in UTF-8, sent as text frames.
- Max accepted inbound frame: 256 KiB. Larger frames are dropped.

## Message envelope

Every message is `{"type": "<name>", ...}`. Unknown types are ignored (logged
in the UI status line), never fatal.

### App → homelab

| type | fields | when |
|---|---|---|
| `hello` | `deviceId` (glasses device id or `unpaired`), `appVersion`, `protocol: 1` | once after each socket open |
| `status` | `glassesConnected: Bool`, `battery: Int?` (0–100, omitted when unknown) | right after `hello` |
| `transcript` | `sessionID`, `text` (≤4000 chars), `final: Bool` | only while live mode is active (v0.2 wiring) |
| `heartbeat` | — | every 20 s while connected |
| `pong` | `ts` (echoed from `ping`) | on ping |

### Homelab → app

| type | fields | effect |
|---|---|---|
| `push_teleprompter` | `text` (required, 1–12,000 chars, ≤48 KiB UTF-8), `mode`: `replace` (default) or `append`, `speed`: 60–240 (default 120) | renders on the lens via the existing `prepareTeleprompter(text, speed:)` seam (business channel 20, `DeviceBusinessWire`); text is also saved to the app's prompter draft (appended with a newline when `append`) |
| `teleprompter_control` | `action`: `pause` \| `resume` \| `stop` | mapped to teleprompter control types 4 / 5 / 6 and sent to the glasses |
| `ping` | `ts` | app replies `pong` with the same `ts` |
| `config_update` | `config`: object | surfaced to the app (currently stored as last inbound event) |

`push_teleprompter` and `teleprompter_control` are only acted on while the
glasses are connected and idle; if the glasses are busy (recording or another
teleprompter session) the existing device-feature guards reject the command and
surface an error in the app UI.

## Connection lifecycle (battery-friendly by design)

- **Live mode** is only active during a real session: it is entered when a
  `push_teleprompter` arrives, when the teleprompter session starts in-app, or
  when the user taps Connect. It expires (default 5 min heartbeat window) when
  the teleprompter session ends.
- Outside a live session the app disconnects and does not hold the socket.
  It reconnects on next foreground (`scenePhase == .active`) or next session.
- Reconnects use exponential backoff: 1, 2, 4, 8, 16, 32 s, capped at 60 s,
  giving up after 8 attempts (retries on the next foreground).
- No APNs/background refresh path exists; the uplink is a foreground feature.
  See ARCHITECTURE.md §7 for the background-reliability caveats.

## Transcript chunks (v0.2 TODO)

`HermesUplink.sendTranscript(_:sessionID:final:)` exists but is not yet wired to
the lifelog capture path in v0.1. Plan (v0.2): feed `AlwaysOnLocalProbe` /
recording-ASR results through the uplink while a capture session is live.

## ASR shim plan (v0.2 TODO)

The ASR host is still regex-locked to `*.aliyuncs.com` DashScope
(`CloudASRHostSettings.normalize`). The LLM executor is already configurable
(`CloudLLMEndpointSettings`, defaulting to the former DeepSeek endpoint and now
pointable at the OpenAI-compatible Hermes endpoint, e.g.
`http://100.77.205.126:8648/v1` with model `hermes-agent`; the key stays in the
Keychain under the existing LLM service). To route ASR through the homelab, the
recommended plan is a **DashScope-protocol-compatible WebSocket shim on the
homelab** wrapping faster-whisper, then relaxing `CloudASRHostSettings.normalize`
to accept the homelab host. No app-side streaming logic changes needed.
