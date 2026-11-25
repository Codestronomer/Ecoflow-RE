// AppModel — the single @Observable state hub shared by the main window,
// the settings window and the menu bar. Owns transport + session.
import AppKit
import Observation
import EcoFlowKit

@MainActor
@Observable
final class AppModel {
    // connection
    private(set) var phase: EcoFlowSession.Phase = .idle
    private(set) var failureText: String?
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var connectedName: String?
    private(set) var stale = false

    // metrics
    private(set) var soc: Double?
    private(set) var packVoltage: Double?
    private(set) var current: Double?
    private(set) var inputWatts: Int?
    private(set) var outputWatts: Int?
    private(set) var batteryTemp: Int?
    private(set) var mosTemp: Int?
    private(set) var cycles: Int?
    private(set) var acEnabled: Bool?
    private(set) var mpptInVoltage: Double?
    private(set) var chargeState: Int?
    private(set) var dc12vWatts: Int?
    private(set) var carOutWatts: Int?
    private(set) var dc24vState: Int?
    // per-module inputs (BMS battery-side, INV AC-side, MPPT solar-side);
    // displayed input = the strongest active source
    private var bmsInputWatts: Int?
    private var invInputWatts: Int?
    private var mpptInputWatts: Int?
    private(set) var packs: [String?] = []
    private(set) var lastFrameDate: Date?

    // logs
    private(set) var logLines: [String] = []
    private(set) var packetLines: [String] = []
    var logPaused = false

    // settings
    var sn: String = ""
    var authSecret: String = ""
    var autoConnect: Bool = true
    var showSOCInMenuBar: Bool = true

    private let transport = RealBleTransport()
    private var session: EcoFlowSession?
    private var stalenessTimer: Timer?
    private var eventsTask: Task<Void, Never>?

    private enum Keys {
        static let sn = "device.sn"
        static let autoConnect = "connect.auto"
        static let menuSOC = "menubar.soc"
        static let lastPeripheral = "device.lastPeripheralUUID"
    }

    init() {
        let d = UserDefaults.standard
        sn = d.string(forKey: Keys.sn) ?? ""
        autoConnect = d.object(forKey: Keys.autoConnect) as? Bool ?? true
        showSOCInMenuBar = d.object(forKey: Keys.menuSOC) as? Bool ?? true
        authSecret = SecretStore.load() ?? ""
    }

    var hasSecret: Bool { !authSecret.isEmpty }

    var statusColor: NSColor { Design.statusColor(phase, stale: stale) }

    var phaseLabel: String {
        switch phase {
        case .idle: return failureText == nil ? "Not connected" : "Failed"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .handshake: return "Handshake…"
        case .auth: return "Authenticating…"
        case .live: return "Live"
        }
    }

    // MARK: connect / disconnect

    func connect() {
        guard session == nil else { return }
        guard hasSecret else {
            failureText = "No auth secret configured. Open Settings to set it."
            return
        }
        failureText = nil
        discovered = []
        soc = nil; packVoltage = nil; current = nil
        inputWatts = nil; outputWatts = nil
        batteryTemp = nil; mosTemp = nil; cycles = nil
        acEnabled = nil; mpptInVoltage = nil; chargeState = nil
        dc12vWatts = nil; carOutWatts = nil; dc24vState = nil
        bmsInputWatts = nil; invInputWatts = nil; mpptInputWatts = nil
        packs = []; lastFrameDate = nil; stale = false

        var config = EcoFlowSession.Config()
        config.sn = sn.isEmpty ? nil : sn
        config.authSecret = Array(authSecret.utf8)
        if autoConnect, let saved = UserDefaults.standard.string(forKey: Keys.lastPeripheral) {
            config.targetID = UUID(uuidString: saved)
        }
        let s = EcoFlowSession(transport: transport, config: config, log: nil)
        s.onEvent = { [weak self] event in self?.handle(event) }
        session = s
        s.start()
        startStalenessTimer()
    }

    func disconnect() {
        session?.stop()
        session = nil
        eventsTask?.cancel(); eventsTask = nil
        stalenessTimer?.invalidate(); stalenessTimer = nil
        phase = .idle
        stale = false
        connectedName = nil
    }

    func connectToDevice(_ device: DiscoveredDevice) {
        session?.connect(to: device.id)
    }

    func clearFailure() {
        failureText = nil
    }

    // MARK: commands

    func setAC(_ on: Bool) {
        session?.sendCommand(src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                             payload: [on ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                             label: on ? "ac-on" : "ac-off")
    }

    func setRTC() {
        session?.sendRtcCommand()
    }

    // MARK: settings persistence

    func persistSettings() {
        let d = UserDefaults.standard
        d.set(sn, forKey: Keys.sn)
        d.set(autoConnect, forKey: Keys.autoConnect)
        d.set(showSOCInMenuBar, forKey: Keys.menuSOC)
        if authSecret.isEmpty { SecretStore.delete() } else { SecretStore.save(authSecret) }
    }

    // MARK: event handling

    private func handle(_ event: EcoFlowSession.Event) {
        defer { NotificationCenter.default.post(name: .appModelChanged, object: self) }
        switch event {
        case .phase(let p):
            phase = p
            if p == .live {
                lastFrameDate = Date()
                stale = false
                if let id = session?.lastDeviceID {
                    UserDefaults.standard.set(id.uuidString, forKey: Keys.lastPeripheral)
                }
                if connectedName == nil {
                    connectedName = session?.lastDeviceID.flatMap { transport.displayName(id: $0) } ?? "Ecoflow-dev"
                }
            }
        case .log(let line):
            appendLog(line)
        case .discovered(let d):
            if !discovered.contains(where: { $0.id == d.id }) { discovered.append(d) }
        case .frame(let f):
            lastFrameDate = Date()
            stale = false
            merge(frame: f)
            appendPacket(f)
        case .failed(let f):
            failureText = Self.failureText(f)
            phase = .idle
        }
    }

    static func failureText(_ f: EcoFlowSession.Failure) -> String {
        switch f {
        case .busyDevice:
            return "The device didn't respond to authentication — it may be busy. Close the EcoFlow app on your phone and try again."
        case .bluetoothOff:
            return "Bluetooth is turned off. Turn it on and retry."
        case .unauthorized:
            return "Bluetooth permission denied for this app."
        case .noDeviceFound:
            return "No EcoFlow device found nearby."
        case .authRejected(let code):
            let hex = code.map { String(format: "%02x", $0) }.joined()
            return "Authentication rejected (code \(hex)). Check the auth secret in Settings."
        case .noResponse:
            return "The device stopped responding."
        case .linkLost:
            return "Connection lost and reconnect attempts exhausted."
        case .cancelled:
            return "Cancelled."
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func appendPacket(_ f: AaFrame) {
        let line = "[DATA] \(String(format: "%02x", f.src))→\(String(format: "%02x", f.dst))"
            + " 0x\(String(format: "%02x", f.cmdFunc))/0x\(String(format: "%02x", f.cmdId))"
            + " len=\(f.len) crc=\(f.isValid ? "ok" : "BAD")"
            + (f.obfuscated ? " obf" : "")
            + "  \(f.payload.hex)"
        packetLines.append(line)
        if packetLines.count > 300 { packetLines.removeFirst(packetLines.count - 300) }
    }

    // MARK: telemetry merge (verified field map — see TELEMETRY-MAP.md)

    private func merge(frame f: AaFrame) {
        let p = f.payload
        func u16(_ i: Int) -> UInt16 { UInt16(p[i]) | (UInt16(p[i+1]) << 8) }
        func u32(_ i: Int) -> UInt32 {
            UInt32(p[i]) | (UInt32(p[i+1]) << 8) | (UInt32(p[i+2]) << 16) | (UInt32(p[i+3]) << 24)
        }
        func f32(_ i: Int) -> Double? {
            guard p.count >= i + 4 else { return nil }
            return Double(Float(bitPattern: u32(i)))
        }
        // The serializer fills non-reporting fields with 0x04 runs (0x04040404)
        // or their bitwise complement (0xFBFBFBxx). Treat any u32 whose top
        // three bytes are all 0x04 or all 0xFB as "no data".
        func isPlaceholder(_ i: Int) -> Bool {
            guard p.count >= i + 4 else { return true }
            let b = (p[i], p[i+1], p[i+2])
            return (b.0 == 0x04 && b.1 == 0x04 && b.2 == 0x04)
                || (b.0 == 0xFB && b.1 == 0xFB && b.2 == 0xFB)
        }

        switch (f.src, f.cmdFunc, f.cmdId) {
        case (0x03, 0x20, 0x02) where p.count >= 46:          // BMS heartbeat 55B
            soc = f32(26).map { $0 / 256.0 } ?? soc
        case (0x03, 0x20, 0x32) where p.count >= 69:          // BMS detailed 188B
            soc = f32(53).map { $0 / 256.0 } ?? soc
            packVoltage = Double(u16(12)) / 1000
            if !isPlaceholder(16) {
                current = Double(Int32(bitPattern: u32(16))) / 1000
            }
            batteryTemp = Int(p[20])
            if !isPlaceholder(34) { cycles = Int(u32(34)) }   // fixes 67372198
            if !isPlaceholder(57) { bmsInputWatts = Int(u32(57)) }
            if !isPlaceholder(61) { outputWatts = Int(u32(61)) }
        case (0x04, 0x20, 0x02) where p.count >= 45:          // INV heartbeat 70B
            if u16(9) != 0x0404 { invInputWatts = Int(u16(9)) }   // AC-input watts
            outputWatts = Int(u16(11))
            mosTemp = Int(p[32])
        case (0x05, 0x20, 0x02) where p.count >= 73:          // MPPT heartbeat 121B
            let inVol = Double(u16(8) | (UInt16(p[10]) << 16) | (UInt16(p[11]) << 24)) / 100.0
            mpptInVoltage = inVol
            chargeState = Int(p[33])
            acProbeDump(p)
            // verified MPPT map offsets (DirectMpptHeartbeatPack)
            if !isPlaceholder(16) { mpptInputWatts = Int(u16(16)) }   // in_watts (solar)
            if !isPlaceholder(42) { dc12vWatts = Int(u16(42)) }       // dcdc12v_watts
            if !isPlaceholder(52) { carOutWatts = Int(u16(52)) }      // car_out_watts
            dc24vState = Int(p[59])                                    // dc24v_state
            // LIVE-VERIFIED via payload diff around an AC off→on command
            // (EF_AC_PROBE): byte 107 tracks the relay state; byte 71 was
            // wrong for this firmware. Lags the relay a few seconds (soft-start).
            if p.count >= 108 {
                acEnabled = p[107] != 0
            }
        case (0x03, 0x03, 0x0e) where p.count >= 5:           // sub-pack info 83B
            let count = Int(u16(3))
            var list: [String?] = []
            var i = 5
            var n = 0
            while i + 39 <= p.count && n < count {
                let snBytes = Array(p[(i+1)...(i+16)])
                let sn = String(bytes: snBytes.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .utf8)
                list.append((sn?.isEmpty ?? true) ? nil : sn)
                i += 39; n += 1
            }
            packs = list
        default:
            break
        }
    }

    // MARK: AC-offset probe (EF_AC_PROBE=<path>)
    // Dumps every MPPT heartbeat payload; after the first live frame, toggles
    // AC off then on so the payload diff reveals the real cfgAc byte.
    private var acProbeArmed = false
    private var acProbeDumpURL: URL?

    private func acProbeDump(_ payload: [UInt8]) {
        guard let path = ProcessInfo.processInfo.environment["EF_AC_PROBE"] else { return }
        let url = URL(fileURLWithPath: path)
        let line = String(format: "MPPT ac=%d: ", acEnabled == true ? 1 : 0)
            + payload.map { String(format: "%02x", $0) }.joined() + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        guard !acProbeArmed else { return }
        acProbeArmed = true
        NSLog("EF-PROBE: armed, toggling AC off in 5s, back on in 13s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            NSLog("EF-PROBE: setAC(false)")
            self?.setAC(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) { [weak self] in
            NSLog("EF-PROBE: setAC(true)")
            self?.setAC(true)
        }
    }

    private func updateInputWatts() {
        let active = [bmsInputWatts, invInputWatts, mpptInputWatts].compactMap { $0 }
        inputWatts = active.max()
    }

    // MARK: staleness watchdog

    private func startStalenessTimer() {
        stalenessTimer?.invalidate()
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .live else { return }
                if let last = self.lastFrameDate, Date().timeIntervalSince(last) > 5 {
                    self.stale = true
                }
            }
        }
    }
}
