# EcoFlow E980 — macOS GUI Client — Specification

Status: draft v1 · Target: macOS 26+ (Apple Silicon & Intel) · Author: project
Companion document: [PLAN.md](PLAN.md)

## 1. Overview

A native macOS SwiftUI application that manages the existing, protocol-complete
BLE client for the EcoFlow E980 (R33/MR330). It replaces the terminal-based
`ble/ecoflow-session` workflow with a proper app: device discovery, one-click
connection, live telemetry dashboard, verified controls, session logs, and
history charts.

The protocol layer is already proven (handshake, auth, telemetry, AC/RTC
commands). The GUI is a new front-end over the same code — no protocol
re-invention.

## 2. Goals / Non-goals

### Goals
- G1. Discover and connect to `Ecoflow-dev` devices; connect/disconnect on demand.
- G2. Run the verified handshake + auth automatically and surface failures clearly.
- G3. Display live telemetry at ≥1 Hz: SOC, pack voltage, current, input/output
  watts, temperatures, cycle count, AC state, MPPT fields, sub-pack list.
- G4. Send verified commands with confirmation: AC on/off, SET RTC.
- G5. Record sessions and show history charts (SOC and power over time).
- G6. Keep credentials safe (Keychain) and diagnostics shareable (redaction).
- G7. Ship as a single `.app` buildable from the CLI toolchain (no Xcode).

### Non-goals (v1)
- Wi-Fi/cloud MQTT or LAN (UDP 6099) transports — BLE only.
- Firmware OTA, device provisioning/binding, account login.
- iOS/iPadOS; multi-device dashboards; scripting/automation APIs.
- Telemetry fields not yet verified (EMS 147B names) — shown raw, not invented.

## 3. Environment & packaging constraints

- Development machine: macOS 26.7.3, Swift 6.4, **Command Line Tools only**
  (no `xcodebuild`). Therefore:
  - Project = SwiftPM package with two targets: library `EcoFlowKit` and
    executable `EcoFlowGUI` (SwiftUI `@main`).
  - The `.app` bundle is assembled by a script: binary + `Info.plist` +
    `PkgInfo` + `Contents/Resources`, then `codesign --force --deep -s -`
    (ad-hoc) with a stable bundle id.
  - `Info.plist` must include `NSBluetoothAlwaysUsageDescription`; the app is
    **not sandboxed** (avoids the `com.apple.security.device.bluetooth`
    entitlement requirement for local builds).
- Bluetooth permission is granted by TCC on first connection attempt.
  Ad-hoc signing with a stable bundle identifier keeps the grant across builds;
  if TCC re-prompts, a `tccutil reset Bluetooth com.ecoflow.gui` hint is shown.
- Deployment target: **macOS 26** — the owner's machine runs 26.7.3 and the app
  uses Liquid Glass materials (`glassEffect`, `containerBackground`). If wider
  OS support is needed later, gate glass behind `#available` and fall back to
  `Material.thin`.

## 4. Users & use cases

- **Owner monitoring**: open app → auto-connect to last device → see SOC and
  power at a glance → close.
- **Owner controlling**: toggle AC with a confirmation; observe the relay click
  and the state change in telemetry.
- **RE/debug**: watch the decoded packet log, export a session for analysis.
- **Cold start**: no saved device → scan list → pick device → enter/derive auth
  secret once → connect.

## 5. Functional requirements

### FR-1 Discovery & connection
- FR-1.1 Scan on launch (optional auto-scan setting); list name, identifier,
  RSSI; filter EcoFlow-named peripherals first, show all others below.
- FR-1.2 Connect with a 15 s timeout; cancel scan while connecting.
- FR-1.3 Remember last peripheral identifier and auto-connect on launch when the
  setting is on.
- FR-1.4 Detect "device busy" (connected to the phone app): connection attempt
  fails or auth times out → show actionable message ("Close the EcoFlow app on
  your phone and retry").
- FR-1.5 Manual disconnect; automatic reconnect with exponential backoff
  (1, 2, 4, 8, 16 s, max 5 attempts) on unexpected loss while in live state.

### FR-2 Session & authentication
- FR-2.1 Execute the verified flow: pubkey exchange → keyInfo → session key →
  getAuthStatus → setAuth/checkAuth → heartbeats (20 s) → live.
- FR-2.2 Show a step-by-step progress indicator (Handshake / Key exchange /
  Auth / Live) with elapsed time.
- FR-2.3 Auth secret: 32-char uppercase hex, entered once; stored in Keychain;
  optional "derive from userId + SN" helper (MD5, local only).
- FR-2.4 Surface device auth codes verbatim (e.g. `04`, `06`) with a short
  explanation; never hide a failure behind a spinner.
- FR-2.5 Heartbeat every 20 s while live; pause during sleep; resume on wake
  with full re-auth if the link dropped.

### FR-3 Live dashboard
- FR-3.1 Metric cards: SOC %, pack voltage, current, input W, output W,
  battery temp, inverter/MOS temp, cycle count, AC state, MPPT input voltage,
  charge state.
- FR-3.2 Update rate: UI refresh at 1 Hz max, coalescing raw frames; stale
  indicator when no frame for >5 s.
- FR-3.3 Sub-pack list: count and serial numbers (redacted toggle).
- FR-3.4 Emphasis: SOC ring + power flow (in/out) as the hero visual; all
  numbers monospaced, no jitter (fixed-width layout).
- FR-3.5 Unknown/placeholder values shown as "—" (never fabricated).

### FR-4 Controls
- FR-4.1 AC output toggle: confirmation sheet ("Turn AC output off?") with the
  current device state shown; disabled when not live.
- FR-4.2 SET RTC: confirmation showing the exact timestamp that will be sent;
  disabled when not live.
- FR-4.3 Command feedback: "sent" → "confirmed by device" when telemetry shows
  the new state (cfgAc / ack), with 10 s timeout → "no confirmation".
- FR-4.4 Raw command drawer (advanced): src/dst/func/id/payload hex, explicit
  warning, single-shot, requires typing "SEND" to enable.

### FR-5 Logs & diagnostics
- FR-5.1 Packet log: timestamp, direction, decrypted aa-frame fields
  (src/dst/cmd/len/seq/crc), payload hex; filter by module/command; pause.
- FR-5.2 Session summary: frames received/sent, CRC failures, obfuscated frame
  count, connection duration.
- FR-5.3 Export log (TXT/JSONL) with redaction of SN, secret, and pack serials.
- FR-5.4 Copy-to-clipboard of a single frame or summary.

### FR-6 History & charts
- FR-6.1 Record live samples every second to a local JSONL file per session.
- FR-6.2 Charts (Swift Charts): SOC (%) and power (in/out W) over the session;
  time-range selector; hover readout.
- FR-6.3 Session list with date, duration, SOC delta; delete/export.

### FR-7 Settings
- FR-7.1 General: auto-connect, auto-scan, UI refresh rate (1/2/5 s).
- FR-7.2 Device: SN (display), auth secret (Keychain), derive-secret helper.
- FR-7.3 Diagnostics: packet log verbosity, redaction on/off (default on),
  "reset Bluetooth permission" hint.
- FR-7.4 About: protocol version, app build, link to repo docs.

### FR-8 Menu bar
- FR-8.1 `MenuBarExtra` is present while the app runs; label shows a connection
  dot plus SOC (label style configurable: icon only / icon + SOC / SOC only).
- FR-8.2 Popover (≈320×380, glass background): compact SOC ring, input/output
  watts, AC switch, connection state, battery temperature, and quick actions —
  "Open Dashboard", "Set Clock…", "Disconnect", "Quit".
- FR-8.3 The popover shares the same live session as the main window — never a
  second BLE connection.
- FR-8.4 AC toggle from the menu bar uses an inline confirm (two-step switch)
  unless "skip confirmations" is enabled in Settings.
- FR-8.5 Menu bar refreshes at most 1 Hz; a stale badge appears when frames stop
  for >5 s; animations disabled under Reduce Motion.

## 6. UX / layout

### 6.1 Design language — modern, simple, sleek

Native macOS 26 aesthetic built on Liquid Glass, with restraint:

- **Material**: glass tiles (`glassEffect(.regular, in: .rect(cornerRadius: 18))`)
  for the hero and metric cards; a floating glass status bar; no heavy
  gradients, no drop shadows beyond system vibrancy.
- **Typography**: SF Pro (system); hero SOC 52 pt rounded semibold; titles 20 pt
  semibold; body 13 pt; captions 11 pt secondary. All live numbers use
  `.monospacedDigit()` so values never jitter.
- **Color**: one accent (EcoFlow green, adaptive for dark mode); semantic status
  colors — green = live, amber = stale, red = error; everything else neutral.
- **Spacing**: 8-pt grid; card padding 16; grid gaps 12; sidebar width 220;
  content max width 780; window default 980×680, min 860×600.
- **Shape & motion**: continuous 16–20 pt radii; one accent stroke at 1 pt,
  8 % opacity; spring transitions only for state changes (connect, confirm),
  150–250 ms; everything respects **Reduce Motion**, **Reduce Transparency**,
  **Increase Contrast**.
- **Iconography**: SF Symbols, hierarchical rendering, 15–17 pt for inline,
  22–26 pt for hero.
- **Tone**: the dashboard answers three questions at a glance — *how much
  charge?*, *is power flowing?*, *is AC on?* Everything else is secondary.

### 6.2 Main window

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ◉ EcoFlow E980        ● Live · 51.65 V · 33 °C            ⌘R  ⚙︎         │
├───────────────┬──────────────────────────────────────────────────────────┤
│  DEVICES      │                                                          │
│  ● E980   -48 │      ╭──────────────────────────────╮                    │
│  ○ scan…      │      │           65.6 %             │   ← glass hero     │
│               │      │      ◜◝  SOC ring  ◟◞        │      + ring        │
│  [ Connect ]  │      ╰──────────────────────────────╯                    │
│               │                                                          │
│  SESSION      │   ┌────────────┐ ┌────────────┐ ┌────────────┐          │
│  ✓ Handshake  │   │  Pack V    │ │  Current   │ │  Input W   │          │
│  ✓ Key        │   │  51.65 V   │ │  −0.67 A   │ │    0 W     │          │
│  ✓ Auth       │   └────────────┘ └────────────┘ └────────────┘          │
│  ● Live 04:21 │   ┌────────────┐ ┌────────────┐ ┌────────────┐          │
│               │   │  Output W  │ │  Batt temp │ │  Cycles    │          │
│  Packs: 2     │   │    0 W     │ │   33 °C    │ │    42      │          │
│               │   └────────────┘ └────────────┘ └────────────┘          │
│               │                                                          │
│               │   AC output   [ ●──── ]        Set clock…                │
├───────────────┴──────────────────────────────────────────────────────────┤
│   Dashboard   Charts   Log   Settings                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Menu bar popover

```
  ⌁ 66%        ← label: icon + SOC (configurable)
 ┌──────────────────────────────┐
 │  ◉ EcoFlow E980    ● Live    │
 │                              │
 │       ╭────────────╮         │
 │       │   65.6 %   │         │
 │       │  ◜ ring ◝  │         │
 │       ╰────────────╯         │
 │    In 0 W      Out 0 W       │
 │    33 °C       51.65 V       │
 │                              │
 │  AC output       [ ●──── ]   │
 │                              │
 │  Open Dashboard…             │
 │  Set Clock…                  │
 │  Disconnect                  │
 │  ─────────────────────────   │
 │  Quit EcoFlow                │
 └──────────────────────────────┘
```

- Both surfaces are the same data, same session, same design tokens.
- Empty/disconnected state: subdued ring, "Not connected", Connect button.

## 7. Architecture

```
EcoFlowGUI (SwiftUI, @main)
 ├─ AppState (@Observable)        // selection, tabs, alerts, menu-bar settings
 ├─ DeviceViewModel (@Observable) // binds EcoFlowKit session → view state
 ├─ Scenes: WindowGroup + MenuBarExtra (popover reuses DeviceViewModel)
 ├─ DesignSystem: GlassCard, MetricTile, SocRing, StatusDot, SwitchRow
 ├─ Views: DeviceList, Dashboard, Charts, LogView, Settings, MenuBarPanel
 └─ Services: KeychainStore, HistoryStore, SecretDeriver

EcoFlowKit (library, no UI)
 ├─ Protocol: SessionHandshake, Secp160, CryptoHelpers  (existing, unchanged)
 ├─ AaFrame: codec + obfuscation + CRC                    (from SessionHandshake)
 ├─ Telemetry: frame routing table, FieldMap, DeviceSnapshot
 ├─ Commands: typed builders (AC, RTC, raw)
 ├─ BleTransport: CBCentralManager wrapper (serial queue, AsyncStream events)
 └─ EcoFlowSession: state machine (idle→scanning→connecting→handshake→auth→live→error)
      - heartbeat timer, command queue with correlation/timeouts, reconnect policy
```

Concurrency: `BleTransport` and `EcoFlowSession` run on a dedicated
`DispatchQueue` (CoreBluetooth requirement); UI receives immutable snapshots via
`AsyncStream`/`@MainActor` delivery. No protocol code runs on the main thread.

Data flow: notify bytes → `AaFrame.parse` → frame router → typed snapshot
merge (apply changed fields only) → 1 Hz publish → SwiftUI diffing.

## 8. Data model (library types)

```swift
struct DeviceSnapshot {          // merged from frames
  var soc: Double?; var packVoltage: Double?; var current: Double?
  var inputWatts: Int?; var outputWatts: Int?; var batteryTemp: Int?
  var mosTemp: Int?; var cycles: Int?; var acEnabled: Bool?
  var mpptInVoltage: Double?; var chargeState: Int?
  var packs: [PackInfo]        // serials optional
  var lastUpdate: Date
}
struct PackInfo { var index: Int; var serial: String? }
struct FrameRecord { let date: Date; let direction: Direction; let frame: AaFrame }
struct Sample { let date: Date; let soc: Double?; let inW: Int?; let outW: Int? }
enum SessionState { case idle, scanning, connecting, handshake, auth, live, failed(String) }
enum Command { case ac(Bool), setRTC(Date), raw(src: UInt8, dst: UInt8, func: UInt8, id: UInt8, payload: [UInt8]) }
```

## 9. Protocol integration (reuse map)

| Need | Source (existing, proven) |
|---|---|
| Frame build/parse, CRC8/16, obfuscation, ECDH glue, key derivation | `ble/SessionHandshake.swift` |
| EC math | `ble/Secp160.swift` |
| MD5 + AES-CBC | `ble/CryptoHelpers.swift` |
| BLE discovery/write/notify, auth state machine, heartbeats, commands | `ble/ecoflow-session.swift` (`SessionClient`) — refactor into kit |
| Field decoding reference | `TELEMETRY-MAP.md`, `ble/decode-telemetry.py` |

Verbatim protocol facts the GUI relies on (see `PROTOCOL-NOTES.md`):
outer `5a5a 10 01`, AES-128-CBC(sessionKey, MD5(share)); inner `aa 02` frame with
16-byte header, CRC8 0x07 + CRC16 0xA001; XOR mask when header[6] ∉ {0x00,0x04};
auth secret = MD5hex(userId + SN); AC = `21→05, 20/42, [01|00, ff×6]`;
RTC = `21→03, 03/40, <8-byte datetime>`; heartbeat `21→02, 20/59` every 20 s.

## 10. Security & privacy

- Auth secret and any future credentials live in the **Keychain**
  (`kSecClassGenericPassword`, service `com.ecoflow.gui`, account = SN).
- No network egress in v1 (no analytics, no crash reporting, no cloud calls).
- History files under `~/Library/Application Support/EcoFlowGUI/`; raw packet
  logs are opt-in per session.
- Redaction by default in exports: SN, secret, pack serials, MAC/UUIDs.
- Write commands require explicit confirmation; raw command mode requires typing
  "SEND"; controls are disabled unless `state == .live`.

## 11. Performance

- Launch to window: <1.5 s (cold), <0.5 s (warm).
- Memory: <150 MB steady with a 60-min session.
- CPU: <3 % idle-live (1 Hz UI, coalesced).
- No main-thread protocol work; no frame drops at 2 Hz raw rate.
- History append must not block the BLE queue (background actor/file handle).

## 12. Accessibility & localization

- Full keyboard navigation (connect ⌘K, disconnect ⌘⇧K, refresh ⌘R, tabs ⌘1–4).
- VoiceOver labels for metric cards and switches; values spoken with units.
- Dynamic Type not applicable (macOS), but text scales with system settings;
  sufficient contrast in both appearances.
- Strings in a String Catalog; English v1, structure ready for pt-BR.

## 13. Testing strategy

- **Unit (EcoFlowKit)**: golden vectors from the protocol docs — builder equals the
  app's known-good frames (`aa020000b50d…c584`, `aa0220001b0d…924b`, AC toggle);
  parser: CRC8/16, length bounds, obfuscation (0x00/0x04 clear, 0xf5→0xf1),
  188B/55B/70B/121B/83B field decode with synthetic payloads.
- **Session tests**: fake transport feeding scripted frames → state machine
  reaches `.live`, heartbeat emitted at 20 s, command correlation + timeout,
  reconnect backoff.
- **UI tests (manual v1, XCUITest v2)**: connect flow, busy-device message,
  confirmation gates, log filter, export redaction.
- **Device-in-the-loop checklist**: connect, SOC accuracy vs app, AC off/on
  (relay + cfgAc), RTC, 10-min stability, sleep/wake, Bluetooth off/on.

## 14. Acceptance criteria (v1)

- [ ] App builds via `./build.sh` on a CLT-only Mac and launches as a signed `.app`.
- [ ] Scans, connects, authenticates, and shows SOC within 3 s of auth success.
- [ ] Dashboard updates ≥1 Hz with no layout jitter; stale badge after 5 s.
- [ ] AC toggle requires confirmation, sends the verified frame, and reports
      device-confirmed state (cfgAc) within 10 s.
- [ ] RTC set shows the exact timestamp and succeeds.
- [ ] Busy-device, wrong-secret, and device-unavailable cases produce clear,
      actionable messages.
- [ ] Secret stored in Keychain; exports redact by default.
- [ ] Session history persists and charts render a 30-min session.
- [ ] 10-minute stability run with zero crashes and no memory growth >20 MB.
- [ ] Menu bar item shows live SOC, opens the popover, and its AC switch works
      without opening a second BLE connection.
- [ ] Design review: one accent color, glass cards, monospaced live numbers, no
      jitter; Reduce Motion / Transparency honoured.

## 15. Risks & open questions

| Risk | Mitigation |
|---|---|
| TCC re-prompts after each ad-hoc build | stable bundle id + documented `tccutil reset`; optional self-signed identity |
| Device accepts one BLE link; phone app holds it | detect + actionable "close the phone app" message; retry button |
| Secret UX is awkward (MD5 of userId+SN) | include derive helper; validate 32 hex chars; show where to find userId |
| SwiftPM SwiftUI app needs manual bundling | `build.sh` script + committed `Info.plist`; smoke test in CI-less env |
| macOS 26 SwiftUI API drift | pin deployment target macOS 14; avoid bleeding-edge APIs |
| Auth state quirks (`05 04` → setAuth → checkAuth) | reuse the CLI's verified state machine; regression tests with recorded frames |
| Sleep/wake, BT toggles | state machine handles `centralManagerDidUpdateState`; full re-auth on resume |
