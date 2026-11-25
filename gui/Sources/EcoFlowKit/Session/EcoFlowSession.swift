// EcoFlowSession — the protocol state machine driven by a Transport.
// Ported verbatim from the proven SessionClient (M1): same frames, same state
// machine (incl. the `05 04 → setAuth → checkAuth → live` path and RTC on auth),
// same log strings. Additions: busy-device timeout, reconnect backoff, events.
import Foundation

public final class EcoFlowSession: TransportDelegate {
    public enum Phase: Equatable { case idle, scanning, connecting, handshake, auth, live }

    public enum Failure: Error, Equatable {
        case bluetoothOff
        case unauthorized
        case noDeviceFound
        case busyDevice              // auth status never answered (phone app holds the link)
        case authRejected(code: [UInt8])
        case noResponse
        case linkLost
        case cancelled
    }

    public struct Config {
        public var targetID: UUID?
        public var sn: String?
        public var authSecret: [UInt8] = []      // MD5hex(userId + SN)
        public var sendSetTime = false
        public var heartbeatInterval: TimeInterval = 20
        public var authTimeout: TimeInterval = 10
        public var maxReconnectAttempts = 5
        public init() {}
    }

    public enum Event {
        case phase(Phase)
        case log(String)
        case discovered(DiscoveredDevice)
        case frame(AaFrame)
        case failed(Failure)
    }

    public let transport: Transport
    public var config: Config
    public private(set) var phase: Phase = .idle
    public private(set) var failure: Failure?
    public private(set) var lastDeviceID: UUID?
    /// Handshake/session crypto state (readable for tests + diagnostics).
    public private(set) var hs = SessionHandshake()

    private var logSink: ((String) -> Void)?
    private var authSecret: [UInt8]
    private var sendSetTime: Bool
    private var buffer: [UInt8] = []
    private var stage = 0        // 0=pubExch, 1=keyInfo, 2=authStatus, 3=authResult, 4=live
    private var pendingCommands: [(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8, payload: [UInt8])] = []
    private var lastAuthCmd: UInt8 = 0
    private var heartbeatTimer: Cancellable?
    private var authTimeoutTimer: Cancellable?
    private var reconnectTimer: Cancellable?
    private var reconnectAttempts = 0
    private var stopped = false
    private var names: [UUID: String] = [:]
    private var connectedID: UUID?
    private var canWriteNR = false
    private var continuation: AsyncStream<Event>.Continuation!
    public let events: AsyncStream<Event>

    /// Injectable scheduler — tests drive timers manually.
    public var scheduler: Scheduler = defaultScheduler
    /// Synchronous event observer (complements `events`; used by tests/UI glue).
    public var onEvent: ((Event) -> Void)?

    public init(transport: Transport, config: Config = Config(), log: ((String) -> Void)? = { print($0) }) {
        self.transport = transport
        self.config = config
        self.authSecret = config.authSecret
        self.sendSetTime = config.sendSetTime
        self.logSink = log
        var c: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(Event.self, bufferingPolicy: .unbounded) { cc in c = cc }
        self.continuation = c
        transport.delegate = self
    }

    deinit { continuation.finish() }

    // MARK: public API

    public func start() {
        stopped = false
        transport.start()
    }

    public func stop() {
        stopped = true
        heartbeatTimer?.cancel()
        authTimeoutTimer?.cancel()
        reconnectTimer?.cancel()
        transport.shutdown()
        setPhase(.idle)
    }

    /// Connect to a specific discovered device (manual pick from the UI).
    public func connect(to id: UUID) {
        connect(id: id)
    }

    /// Queue a command; sent immediately when live, else after auth success.
    public func sendCommand(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                            payload: [UInt8], label: String = "user-cmd") {
        guard phase == .live, connectedID != nil else {
            pendingCommands.append((src, dst, cmdFunc, cmdId, payload))
            log("[cmd] queued (not live)")
            return
        }
        sendNow(src: src, dst: dst, cmdFunc: cmdFunc, cmdId: cmdId, payload: payload, label: label)
    }

    // MARK: plumbing

    private func emit(_ e: Event) {
        continuation.yield(e)
        onEvent?(e)
    }

    private func log(_ line: String) {
        logSink?(line)
        emit(.log(line))
    }

    private func setPhase(_ p: Phase) {
        guard phase != p else { return }
        phase = p
        emit(.phase(p))
    }

    private func fail(_ f: Failure) {
        log("[error] \(f)")
        failure = f
        heartbeatTimer?.cancel()
        authTimeoutTimer?.cancel()
        emit(.failed(f))
        transport.shutdown()
        setPhase(.idle)
    }

    private func connect(id: UUID) {
        let n = transport.displayName(id: id) ?? names[id] ?? "Ecoflow-dev"
        log("[ble] connecting \(n)")
        setPhase(.connecting)
        transport.connect(id: id)
    }

    private func writeChunks(id: UUID, data: Data, label: String) {
        let type = canWriteNR ? "nr" : "wr"
        transport.write(id: id, data: data)
        log("[tx] \(label) (\(type)): \([UInt8](data).hex)")
    }

    private func sendNow(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                         payload: [UInt8], label: String) {
        let enc = SessionHandshake.buildAaEncrypted(src: src, dst: dst, cmdFunc: cmdFunc,
                                                    cmdId: cmdId, payload: payload,
                                                    ctr: 0, ctr2: 0,
                                                    key: hs.sessionKey, iv: hs.aesIv)
        writeChunks(id: connectedID ?? lastDeviceID ?? UUID(), data: enc, label: label)
    }

    // MARK: TransportDelegate

    public func transport(_ t: Transport, didUpdateState state: TransportState) {
        switch state {
        case .poweredOn:
            log("[ble] powered on")
            if let id = config.targetID {
                connect(id: id)
                return
            }
            setPhase(.scanning)
            t.scan()
        case .poweredOff:   log("[ble] Bluetooth OFF")
        case .unauthorized: log("[ble] Bluetooth permission DENIED")
        case .other(let n): log("[ble] state: \(n)")
        }
    }

    public func transport(_ t: Transport, didDiscover device: DiscoveredDevice) {
        emit(.discovered(device))
        let name = device.name ?? "?"
        log("[scan] \(name) id=\(device.id) rssi=\(device.rssi)")
        if name.lowercased().contains("ecoflow") || name.lowercased().contains("r33") {
            t.stopScan()
            connect(id: device.id)
        }
    }

    public func transport(_ t: Transport, didConnect id: UUID, name: String?) {
        lastDeviceID = id
        connectedID = id
        if let n = name { names[id] = n }
        log("[ble] connected")
        setPhase(.connecting)
    }

    public func transport(_ t: Transport, didDisconnect id: UUID, error: Error?) {
        heartbeatTimer?.cancel()
        authTimeoutTimer?.cancel()
        guard !stopped else { return }
        // any unexpected disconnect goes through the reconnect policy; the
        // backoff only resets once a live session is re-established
        scheduleReconnect()
    }

    public func transport(_ t: Transport, didReceive id: UUID, data: [UInt8]) {
        handleReceive(data)
    }

    public func transport(_ t: Transport, didFailWrite id: UUID, error: Error?) {
        log("[tx-err] \(error.map { $0.localizedDescription } ?? "write error")")
    }

    public func transport(_ t: Transport, characteristicsReady id: UUID, withoutResponse: Bool) {
        connectedID = id
        canWriteNR = withoutResponse
        log("[ble] session starting")
        setPhase(.handshake)
        let frame = hs.startExchange()
        writeChunks(id: id, data: frame, label: "pubkey-exchange")
    }

    // MARK: receive path (ported from the proven CLI)

    private func handleReceive(_ data: [UInt8]) {
        buffer += data
        log("[rx-raw] \(data.count)B: \(data.prefix(40).hex)")

        guard let parsed = SessionHandshake.parseV4Frame(buffer, key: hs.sessionKey, iv: hs.aesIv) else {
            if buffer.count > 4096 { buffer.removeFirst(2048) }
            return
        }
        buffer.removeFirst(parsed.consumed)
        let (payload, encrypted, _) = parsed
        guard !payload.isEmpty else { return }
        log("[rx] enc=\(encrypted) len=\(payload.count): \(payload.prefix(48).hex)")

        switch stage {
        case 0:
            if payload[0] == 0x01, payload.count >= 43 {
                if let next = hs.onPubKeyResponse(payload) {
                    stage = 1
                    writeChunks(id: connectedID ?? lastDeviceID ?? UUID(), data: next, label: "getKeyInfoReq")
                }
            }
        case 1:
            if payload[0] == 0x02, payload.count >= 17 {
                if hs.onKeyInfoResponse(payload) {
                    stage = 2
                    log("[session] ESTABLISHED — sessionKey = MD5(login_key[seed0*16+(seed1-1)*256] || sRand)[0:16]")
                    log("[hs] sessionKey: " + hs.sessionKey.hex)
                    setPhase(.auth)
                    let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x89,
                                                              payload: [], ctr: 0, ctr2: 0,
                                                              key: hs.sessionKey, iv: hs.aesIv)
                    writeChunks(id: connectedID ?? lastDeviceID ?? UUID(), data: f, label: "getAuthStatus-aa")
                    armAuthTimeout()
                }
            }
        case 2:
            authTimeoutTimer?.cancel()
            if let aa = AaFrame.parse(payload) {
                log("[auth-ack] src=0x\(String(format: "%02x", aa.src)) dst=0x\(String(format: "%02x", aa.dst)) cmd=0x\(String(format: "%02x", aa.cmdFunc))/0x\(String(format: "%02x", aa.cmdId)) payload=\(aa.payload.hex)")
                let authed = aa.payload.count >= 1 && aa.payload[0] == 1
                let omos = aa.payload.count >= 2 && aa.payload[1] == 1
                log("[auth] authed=\(authed) omos=\(omos)")
                stage = 3
                let cmdId: UInt8 = authed ? 0x86 : 0x85
                lastAuthCmd = cmdId
                let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: cmdId,
                                                          payload: authSecret, ctr: 0, ctr2: 0,
                                                          key: hs.sessionKey, iv: hs.aesIv)
                writeChunks(id: connectedID ?? lastDeviceID ?? UUID(), data: f,
                            label: cmdId == 0x86 ? "checkAuth-aa" : "setAuth-aa")
            } else {
                log("[auth] not an aa-frame: \(payload.map { String(format: "%02x", $0) }.joined().prefix(80))")
            }
        case 3:
            if let aa = AaFrame.parse(payload) {
                if aa.cmdFunc == 0x35 {
                    // auth-command response (0x35/0x85 setAuth, 0x35/0x86 checkAuth)
                    log("[auth-resp] cmd=0x\(String(format: "%02x", aa.cmdId)) payload=\(aa.payload.hex)")
                    switch aa.cmdId {
                    case 0x85:
                        if aa.payload.first == 0 {
                            // setAuth accepted — the app then ends auth; we also send
                            // checkAuth (the device starts its telemetry stream after it)
                            log("[auth] setAuth OK — sending checkAuth")
                            let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x86,
                                                                      payload: authSecret, ctr: 0, ctr2: 0,
                                                                      key: hs.sessionKey, iv: hs.aesIv)
                            writeChunks(id: connectedID ?? lastDeviceID ?? UUID(), data: f, label: "checkAuth-aa")
                        } else {
                            log("[auth] setAuth FAILED code: \(aa.payload.hex)")
                            fail(.authRejected(code: aa.payload))
                        }
                    case 0x86:
                        if aa.payload.first == 0 {
                            log("[auth] checkAuth OK")
                        } else {
                            log("[auth] checkAuth code \(aa.payload.hex) — device streams regardless, proceeding")
                        }
                        enterLive()
                    default:
                        if aa.payload.first == 0 { enterLive() }
                    }
                } else {
                    // device already streaming telemetry — go live and use this frame
                    log("[auth] device is streaming — entering live mode")
                    enterLive()
                    emitFrame(aa)
                }
            } else {
                log("[auth-resp] raw: \(payload.map { String(format: "%02x", $0) }.joined().prefix(80))")
            }
        case 4:
            if let aa = AaFrame.parse(payload) {
                emitFrame(aa)
            } else {
                log("[RX] raw: \(payload.map { String(format: "%02x", $0) }.joined().prefix(120))")
            }
        default: break
        }
        if buffer.count > 4096 { buffer.removeFirst(2048) }
    }

    // MARK: telemetry emit (ported)

    private func emitFrame(_ aa: AaFrame) {
        emit(.frame(aa))
        let obf = aa.obfuscated ? " OBFUSCATED(decoded)" : ""
        log("[DATA] src=0x\(String(format: "%02x", aa.src)) dst=0x\(String(format: "%02x", aa.dst)) cmd=0x\(String(format: "%02x", aa.cmdFunc))/0x\(String(format: "%02x", aa.cmdId)) len=\(aa.len) seq=0x\(String(format: "%04x", aa.seq)) crc=\(aa.isValid ? "ok" : "BAD")\(obf)")
        log("[DATA] payload=\(aa.payload.hex)")
        decodeTelemetry(src: aa.src, cmdFunc: aa.cmdFunc, cmdId: aa.cmdId, payload: aa.payload)
    }

    // Semantic decoding — definitive field map from the app's own parser chain
    // (kt.a "MR330BleCallBack" → eu.t "MR330ParseHelper" → Direct*HeartbeatPack).
    // See TELEMETRY-MAP.md. All offsets verified against 2 live captures.
    private func decodeTelemetry(src: UInt8, cmdFunc: UInt8, cmdId: UInt8, payload: [UInt8]) {
        func u16(_ i: Int) -> UInt16 { UInt16(payload[i]) | (UInt16(payload[i+1]) << 8) }
        func u32(_ i: Int) -> UInt32 {
            UInt32(payload[i]) | (UInt32(payload[i+1]) << 8) |
            (UInt32(payload[i+2]) << 16) | (UInt32(payload[i+3]) << 24)
        }
        func f32(_ i: Int) -> Float? {
            guard payload.count >= i + 4 else { return nil }
            return Float(bitPattern: u32(i))
        }
        switch (src, cmdFunc, cmdId) {
        case (0x03, 0x20, 0x02) where payload.count >= 46:   // BMS heartbeat 55B = DirectEmsDeltaHeartbeatPack
            let soc = f32(26).map { $0 / 256.0 }
            log("  [BMS] soc=\(soc.map { String(format: "%.1f%%", $0) } ?? "?")"
                  + " chgVol=\(String(format: "%.3fV", Double(u16(3)) / 1000))"
                  + " paraMin=\(String(format: "%.3fV", Double(u16(35)) / 1000))"
                  + " paraMax=\(String(format: "%.3fV", Double(u16(39)) / 1000))"
                  + " lcdSoc=\(payload[14])%")
        case (0x03, 0x20, 0x32) where payload.count >= 69:   // BMS detailed 188B = DirectBmsMDeltaHeartbeatPack
            let soc = f32(53).map { $0 / 256.0 }
            let v = Double(u16(12)) / 1000
            func val32(_ i: Int) -> String {
                let x = u32(i)
                return x == 0x04040404 ? "-" : String(x)
            }
            let ampStr: String
            if payload[18] == 0x04 && payload[19] == 0x04 {
                ampStr = String(format: "%.2fA", Double(Int16(bitPattern: u16(16))) / 1000)
            } else {
                ampStr = String(format: "%.2fA", Double(Int32(bitPattern: u32(16))) / 1000)
            }
            log("  [BMS] soc=\(soc.map { String(format: "%.1f%%", $0) } ?? "?")"
                  + " packV=\(String(format: "%.3fV", v))"
                  + " amp=\(ampStr)"
                  + " temp=\(payload[20])°C cycles=\(val32(34))"
                  + " inW=\(val32(57)) outW=\(val32(61))"
                  + " remainMin=\(val32(65))")
        case (0x04, 0x20, 0x02) where payload.count >= 45:   // INV heartbeat 70B = DirectInvDeltaHeartbeatPack
            log("  [INV] inW=\(u16(9)) outW=\(u16(11))"
                  + " outTemp=\(payload[32])°C fanState=\(payload[42])"
                  + " xboost=\(payload[44])")
        case (0x03, 0x03, 0x0e) where payload.count >= 5:    // sub-pack info 83B
            let count = Int(u16(3))
            var i = 5
            log("  [PACKS] count=\(count)")
            var n = 0
            while i + 39 <= payload.count && n < count {
                let snBytes = Array(payload[(i+1)...(i+16)])
                let sn = String(bytes: snBytes.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .utf8) ?? ""
                log("    pack\(n): sn=\(sn)")
                i += 39; n += 1
            }
        case (0x05, 0x20, 0x02) where payload.count >= 73:   // MPPT heartbeat 121B
            // classic DirectMpptHeartbeatPack layout; inVol in 0.01 V units
            log("  [MPPT] inVol=\(String(format: "%.2fV", Double(u16(8) | (UInt16(payload[10]) << 16) | (UInt16(payload[11]) << 24)) / 100.0))"
                  + " inW=\(u16(16)) outW=\(u16(26))"
                  + " mpptTemp=\(u16(28)) chgState=\(payload[33])"
                  + " cfgAc=\(payload[71]) xboost=\(payload[72])")
        default:
            break
        }
    }

    // MARK: live transitions + commands

    // Transition to live mode exactly once: heartbeats, SET RTC (the app does
    // this on every connect), then any queued user commands.
    private func enterLive() {
        guard stage != 4 else { return }
        stage = 4
        reconnectAttempts = 0        // a live session resets the reconnect backoff
        setPhase(.live)
        log("[auth] SUCCESS — authenticated! heartbeats + data stream")
        scheduleHeartbeat()
        sendRtcCommand()
        if sendSetTime { sendRtcCommand() }
        for c in pendingCommands {
            sendNow(src: c.src, dst: c.dst, cmdFunc: c.cmdFunc, cmdId: c.cmdId,
                    payload: c.payload, label: "user-cmd")
        }
    }

    private func scheduleHeartbeat() {
        guard phase == .live else { return }
        heartbeatTimer = scheduler(config.heartbeatInterval) { [weak self] in
            guard let self = self, self.phase == .live, let id = self.connectedID else { return }
            let enc = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x02, cmdFunc: 0x20, cmdId: 0x59,
                                                        payload: [], ctr: 0, ctr2: 0,
                                                        key: self.hs.sessionKey, iv: self.hs.aesIv)
            self.writeChunks(id: id, data: enc, label: "heartbeat-aa")
            self.scheduleHeartbeat()
        }
    }

    private func armAuthTimeout() {
        authTimeoutTimer?.cancel()
        authTimeoutTimer = scheduler(config.authTimeout) { [weak self] in
            guard let self = self, self.stage == 2 else { return }
            self.log("[error] no response to auth status — device busy? (close the phone app and retry)")
            self.fail(.busyDevice)
        }
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < config.maxReconnectAttempts, let id = lastDeviceID else {
            fail(.linkLost)
            return
        }
        reconnectAttempts += 1
        let delay = min(16.0, pow(2.0, Double(reconnectAttempts - 1)))
        log("[reconnect] attempt \(reconnectAttempts) in \(Int(delay))s")
        reconnectTimer = scheduler(delay) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.hs = SessionHandshake()          // fresh handshake state
            self.stage = 0
            self.buffer = []
            self.setPhase(.connecting)
            self.transport.connect(id: id)
        }
    }

    // SET RTC — payload format verified from the app's own live session:
    //   u16 year LE, month, day, hour, minute, second, ISO weekday (Mon=1..Sun=7)
    public func sendRtcCommand() {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let y = cal.component(.year, from: now)
        let mo = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        let h = cal.component(.hour, from: now)
        let mi = cal.component(.minute, from: now)
        let s = cal.component(.second, from: now)
        let sunBased = cal.component(.weekday, from: now)   // Sunday=1..Saturday=7
        let isoWeekday = (sunBased + 5) % 7 + 1
        let payload: [UInt8] = [UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF),
                                UInt8(mo), UInt8(d), UInt8(h), UInt8(mi), UInt8(s), UInt8(isoWeekday)]
        log("[cmd] SET RTC -> \(y)-\(mo)-\(d) \(h):\(mi):\(s) wk=\(isoWeekday)")
        sendCommand(src: 0x21, dst: 0x03, cmdFunc: 0x03, cmdId: 0x40,
                    payload: payload, label: "set-rtc")
    }
}
