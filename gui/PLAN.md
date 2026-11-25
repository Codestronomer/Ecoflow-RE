# EcoFlow E980 — macOS GUI Client — Implementation Plan

Companion to [SPEC.md](SPEC.md). Toolchain: macOS 26.7.3, Swift 6.4,
Command Line Tools only (no Xcode) → SwiftPM + scripted `.app` bundling.

## Principles

1. **Single source of truth for the protocol.** The proven protocol code moves
   into one library (`EcoFlowKit`); both the CLI and the GUI use it. No copied
   protocol implementations.
2. **Headless first.** Every session-engine feature is testable without UI
   (golden frames + fake transport) before it gets a widget.
3. **Small vertical slices.** Each milestone ends with something runnable and
   verifiable against the real device.
4. **No invented telemetry.** Unknown fields render as "—"; only verified
   offsets are decoded.

## Milestones at a glance

| # | Milestone | Deliverable | Effort | Depends on |
|---|---|---|---|---|
| M0 | Package + kit extraction | `EcoFlowKit` builds; CLI still works | 0.5–1 d | — |
| M1 | Transport + session engine | headless connect/auth/telemetry/commands + tests | 1–1.5 d | M0 |
| M2 | App shell + menu bar | `.app` launches, scans, connects, status + log, `MenuBarExtra` popover | 1–1.5 d | M1 |
| M3 | Live dashboard | SOC/volts/amps/watts/temps/packs, 1 Hz | 1 d | M2 |
| M4 | Controls | AC toggle, RTC, confirmation + feedback | 1 d | M3 |
| M5 | History + charts | recording, charts, export with redaction | 1 d | M3 |
| M6 | Settings + packaging polish | Keychain UX, derive-secret, build.sh, docs | 1 d | M4, M5 |

Total ≈ 6–7.5 focused days.

## Target file tree

```
gui/
├── SPEC.md                      (this pair)
├── PLAN.md
├── Package.swift                SwiftPM: EcoFlowKit (lib), EcoFlowCLI (exe), EcoFlowGUI (exe)
├── Info.plist                   bundle id com.ecoflow.gui, NSBluetoothAlwaysUsageDescription
├── build.sh                     build → assemble .app → ad-hoc codesign
├── Sources/
│   ├── EcoFlowKit/
│   │   ├── Protocol/            ← moved from ble/: SessionHandshake.swift, Secp160.swift, CryptoHelpers.swift
│   │   ├── Frame/               AaFrame.swift (parse/build), Crc.swift, Obfuscation.swift
│   │   ├── Transport/           BleTransport.swift (CBCentralManager wrapper, AsyncStream)
│   │   ├── Session/             EcoFlowSession.swift (state machine, heartbeats, command queue)
│   │   ├── Telemetry/           Router.swift, FieldMap.swift, DeviceSnapshot.swift, Parser.swift
│   │   ├── Commands/            Command.swift, Builders.swift
│   │   └── Support/             KeychainStore.swift, Redactor.swift, HistoryStore.swift
│   ├── EcoFlowCLI/
│   │   └── main.swift           ← thin wrapper over EcoFlowKit (replaces logic in ble/ecoflow-session.swift)
│   └── EcoFlowGUI/
│       ├── EcoFlowGUIApp.swift  @main, WindowGroup, Settings scene
│       ├── AppState.swift       @Observable app-level state
│       ├── DeviceViewModel.swift
│       ├── Views/               DeviceListView, DashboardView, MetricCard, ChartsView,
│       │                        LogView, SettingsView, ConfirmationSheets
│       └── Resources/           Assets.xcassets, String Catalog
└── Tests/
    └── EcoFlowKitTests/
        ├── GoldenFrameTests.swift     known-good app frames
        ├── CrcTests.swift
        ├── ObfuscationTests.swift
        ├── TelemetryDecodeTests.swift synthetic 55B/188B/70B/121B/83B payloads
        └── SessionStateMachineTests.swift fake transport scenarios
```

## M0 — Package + kit extraction

- [x] Created `gui/Package.swift` (SwiftPM, platforms `.macOS(.v26)`, tools
      version 6.2; products: lib `EcoFlowKit`, exe `EcoFlowCLI`).
- [x] Protocol files moved from `ble/` into `Sources/EcoFlowKit/Protocol/`
      (names and code unchanged).
- [x] `SessionClient` extracted into `EcoFlowKit/Session/SessionClient.swift`
      (same state machine incl. `05 04 → setAuth → checkAuth → live`, RTC on
      auth, log-sink indirection; auth secret now a settable property — no
      hardcoding). `AsyncStream` conversion deferred to M1 (callbacks kept).
- [x] Added `Sources/EcoFlowCLI/main.swift` with all CLI flags
      (`--sn/--id/--seconds/--secret/--ac/--set-time/--send-cmd/--logfile`)
      plus `ECOFLOW_AUTH_SECRET` env fallback.
- [x] Golden-frame tests added now (8 tests: getAuthStatus/heartbeat/AC
      builders vs the app's frames, CRC8 vectors, CRC16 round-trip,
      obfuscation round-trips) — all green via `swift test`.
- [x] Acceptance: `swift build` + `swift build -c release` succeed; CLI usage
      output identical; telemetry decode unchanged. (On-device CLI run pending
      — needs Bluetooth TCC in the running terminal, verified next session.)
- [ ] Commit: "Restructure into SwiftPM: EcoFlowKit library + CLI target".

## M1 — Transport + session engine (headless)

- [ ] `BleTransport`: scan/stop/connect/disconnect, characteristic discovery,
      chunked writes (`maximumWriteValueLength`), notify subscription, RSSI;
      events as `AsyncStream<TransportEvent>`; serial `DispatchQueue`.
- [ ] `EcoFlowSession`: `connect(peripheral)` → handshake → auth → live;
      heartbeat timer (20 s); command queue with per-command timeout and
      device-state confirmation; reconnect policy (1–16 s backoff, 5 tries).
- [ ] `Frame` codec: parse/build identical to the CLI; expose `AaFrame` model,
      CRC results, obfuscation flag.
- [ ] Tests:
  - golden builders equal `aa020000b50d…c584`, `aa0220001b0d…924b`, AC `21→05 20/42`,
    RTC `21→03 03/40`, heartbeat;
  - parser: bounds/length/CRC errors, obfuscation cases (`[6]=0x00/0x04` clear,
    `0xf5→0xf1`, `0xb8→0xbc`, `0x81→0x85`);
  - fake transport scripts a full auth + telemetry sequence → `.live`, snapshot
    fields correct, heartbeat emitted, AC command confirmed in ≤10 s;
  - timeout path: no ack → `.failed(.noResponse)`; busy device → `.failed(.busy)`.
- [ ] Acceptance: `swift test` green; `EcoFlowCLI` prints the same telemetry
      values as before refactor.
- [ ] Commit: "Add EcoFlowKit transport, session engine, frame codec + tests".

## M2 — App shell + menu bar

- [ ] `DesignSystem`: design tokens (spacing 8-pt grid, radii, one accent,
      semantic status colors) + components `GlassCard`, `MetricTile`, `SocRing`,
      `StatusDot`, `SwitchRow`; all using macOS 26 Liquid Glass
      (`glassEffect`, `containerBackground`); Reduce Motion / Transparency
      respected from day one.
- [ ] `EcoFlowGUIApp`: `WindowGroup` (default 980×680, min 860×600), floating
      glass toolbar, status dot, `Settings` scene, `MenuBarExtra` scene.
- [ ] `DeviceViewModel`: binds `EcoFlowSession` events → `@Observable` state;
      1 Hz publish throttle.
- [ ] `DeviceListView`: scan results (name, id, RSSI, last seen), connect /
      disconnect, saved device, busy-device alert, permission-denied alert.
- [ ] `LogView`: streaming packet log with filters, pause, copy.
- [ ] `MenuBarExtra`: label (icon + SOC, configurable) and `MenuBarPanel`
      popover (SOC ring, in/out W, temp, AC switch with inline confirm,
      Open Dashboard / Set Clock / Disconnect / Quit) sharing the same
      `DeviceViewModel` — no second BLE connection.
- [ ] `build.sh`: `swift build -c release`, assemble `EcoFlowGUI.app`
      (Contents/MacOS + Info.plist + PkgInfo), `codesign --force --deep -s -`.
- [ ] Acceptance: app launches, lists the E980, connects and reaches `.live`
      (session pane shows steps), log fills; disconnect works; menu bar item
      shows SOC and the popover controls the same session.
- [ ] Commit: "Add SwiftUI shell, design system and menu bar".

## M3 — Live dashboard

- [ ] `DashboardView`: hero `SocRing` (glass, animated only on state change) +
      `MetricTile` grid: pack V, current, in/out W, battery/MOS temps, cycles,
      AC state, MPPT in-voltage, charge state.
- [ ] Snapshot merge in `DeviceViewModel` (apply changed fields only; stale
      badge >5 s; "—" for unknown).
- [ ] Sub-pack section (count + serials, redacted by default).
- [ ] Layout polish: fixed-width numerics, no jitter on update, window resizing.
- [ ] Acceptance: values match the phone app (±1 unit); 1 Hz updates for 10 min
      with no visual jitter; stale indicator appears when frames stop.
- [ ] Commit: "Add live telemetry dashboard with snapshot merging".

## M4 — Controls

- [ ] AC toggle with confirmation sheet (current state shown), disabled unless
      live; optimistic "sent" + device-confirmed "on/off" feedback via `cfgAc`.
- [ ] SET RTC sheet with exact timestamp; disabled unless live.
- [ ] Raw command drawer (advanced): validate hex, require typing "SEND",
      single-shot, log the result.
- [ ] Command errors: not-live, timeout, CRC failure, device NAK (`f0 01`).
- [ ] Acceptance: AC off/on verified by relay click + dashboard state; RTC
      succeeds; commands blocked outside live state; raw mode cannot fire
      accidentally.
- [ ] Commit: "Add AC, RTC and guarded raw command controls".

## M5 — History + charts

- [ ] `HistoryStore`: JSONL per session (1 sample/s: time, SOC, in/out W,
      volts, amps); rotation; metadata header (app version, SN hash).
- [ ] `ChartsView` (Swift Charts): SOC + power over session, range selector,
      hover readout; session list (date, duration, SOC delta).
- [ ] Export: CSV + JSONL, redaction pass (SN/secret/serials), share sheet.
- [ ] Acceptance: 30-min session records and renders; export opens cleanly and
      contains no identifiers with redaction on.
- [ ] Commit: "Add session history, charts and redacted export".

## M6 — Settings, security, packaging polish

- [ ] `SettingsView`: auto-connect, auto-scan, refresh rate, log verbosity,
      redaction toggle, reset-Bluetooth hint.
- [ ] `KeychainStore` for the auth secret (add/update/delete); derive-secret
      helper (userId + SN → MD5, uppercase hex, local only) with validation.
- [ ] Reconnect UX: banner with attempt count + cancel; last-device restore.
- [ ] Menu bar settings: label style (icon / icon+SOC / SOC), "skip
      confirmations" toggle, stale-badge behaviour.
- [ ] Design polish pass: glass materials tuning, keyboard shortcuts, focus
      rings, Reduce Motion/Transparency audit, dark/light screenshots.
- [ ] `README.md` for the GUI (build, run, permissions, troubleshooting);
      screenshots placeholder.
- [ ] Acceptance: clean install → scan → enter secret once → connect; relaunch
      auto-connects without re-entering the secret; permission reset flow works.
- [ ] Commit: "Add settings, Keychain secret UX and packaging polish".

## Build & packaging (reference)

```bash
cd gui
swift build -c release
APP=build/EcoFlowGUI.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EcoFlowGUI "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
open "$APP"
```

`Info.plist` essentials:

```xml
<key>CFBundleIdentifier</key><string>com.ecoflow.gui</string>
<key>CFBundleExecutable</key><string>EcoFlowGUI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connects to your EcoFlow power station to read telemetry and send commands.</string>
```

If TCC keeps re-prompting after ad-hoc rebuilds:
`tccutil reset Bluetooth com.ecoflow.gui`.

## Test matrix

| Layer | What | Where |
|---|---|---|
| Unit | CRC8/16, builders vs golden frames, obfuscation, field decode | `Tests/EcoFlowKitTests` |
| Session | auth sequences, timeouts, busy device, heartbeat cadence, reconnect | fake transport |
| CLI | flag parity, log output | manual + script |
| GUI | connect flow, busy/wrong-secret alerts, confirmation gates, stale badge | manual checklist |
| Device | SOC vs phone app, AC relay + cfgAc, RTC, 10-min soak, sleep/wake, BT toggle | physical E980 |

## Risks

| Risk | Mitigation |
|---|---|
| SwiftPM GUI + manual bundle is unusual | `build.sh` committed and tested early (M2) |
| TCC re-prompts / no permission | stable bundle id, documented reset, non-sandboxed build |
| Device busy (phone app) | explicit detection + retry UX |
| Protocol regression during refactor | golden-frame tests locked before moving code (M0) |
| Time sink on UI polish | fixed scope: cards + charts + log, no theming rabbit hole |

## Definition of done (v1)

All SPEC §14 acceptance criteria met, `swift test` green, `build.sh` produces a
launchable signed `.app`, and a 10-minute device session (SOC, AC toggle, RTC,
charts, export, menu bar popover) passes the manual checklist, including the
design review (one accent, glass cards, monospaced numerics, Reduce Motion).

## Suggested order of execution

1. M0 (refactor only — no behaviour change; golden tests first).
2. M1 (headless engine; verify against the device with the CLI).
3. M2 → M3 (shell → dashboard; first visible milestone).
4. M4 (controls; physical verification).
5. M5 (history) → M6 (settings/packaging).
