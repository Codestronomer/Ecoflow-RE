// EcoFlow E980 BLE client — verified protocol (from the app's own live session).
// Handshake: ECDH → keyInfo → sessionKey = MD5(login_key[seed0*16+(seed1-1)*256] || sRand)
// Session frames: outer 5a5a 10 01 len AES-CBC(key, MD5(share), AA-frame + PKCS) crc
// AA-frame: aa 02 <len> <flags> <ctr4> <ctr2 4> <src> <dst> <cmd_func> <cmd_id> <payload> <crc16>
import Foundation
import CoreBluetooth
import CommonCrypto
import Security

var hs = SessionHandshake()
var sessionFrames: [[UInt8]] = []
var commLog: [String] = []

@main
struct EcoFlowMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let client = SessionClient()

        if args.first == "run" {
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--sn": i += 1; client.sn = args[i]
                case "--id": i += 1; client.targetID = UUID(uuidString: args[i])
                case "--seconds": i += 1; client.runtimeSeconds = Int(args[i]) ?? 300
                case "--set-time": client.sendSetTime = true
                case "--secret":
                    i += 1
                    if let b = hexBytes(args[i]) { client.authSecret = b }
                    else { print("bad --secret hex"); exit(1) }
                case "--ac":
                    // verified from the app: AC toggle = 21→05 (MPPT), 0x20/0x42,
                    // payload [state][ff x6]; 0x01=on 0x00=off
                    i += 1
                    let on = (args[i] == "on")
                    client.pendingCommands.append((0x21, 0x05, 0x20, 0x42,
                                                   [on ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
                case "--send-cmd":
                    // --send-cmd <src> <dst> <cmd_func> <cmd_id> <payload-hex>
                    // e.g. RTC: --send-cmd 21 03 03 40 ea070b1611231e07
                    guard i + 5 < args.count else { print("--send-cmd needs src dst func id payloadhex"); exit(1) }
                    if let s = UInt8(args[i+1], radix: 16), let d = UInt8(args[i+2], radix: 16),
                       let cf = UInt8(args[i+3], radix: 16), let ci = UInt8(args[i+4], radix: 16),
                       let pl = hexBytes(args[i+5]) {
                        client.pendingCommands.append((s, d, cf, ci, pl))
                    } else { print("bad --send-cmd args"); exit(1) }
                    i += 5
                case "--logfile": i += 1
                    let path = args[i]
                    _ = FileManager.default.createFile(atPath: path, contents: nil)
                    if let fh = FileHandle(forWritingAtPath: path) {
                        dup2(fh.fileDescriptor, 1); dup2(fh.fileDescriptor, 2); setbuf(stdout, nil)
                    }
                default: break
                }
                i += 1
            }
            client.runtimeSeconds = max(client.runtimeSeconds, 60)
        } else {
            print("usage: ecoflow-session run [--sn SN] [--id UUID] [--seconds N] [--logfile path]")
            print("          [--set-time] [--send-cmd <src> <dst> <func> <id> <payloadhex>]...")
            exit(0)
        }
        client.run()
    }
}

func hexBytes(_ s: String) -> [UInt8]? {
    var out: [UInt8] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        guard next > idx, let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}

class SessionClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    var notifyChar: CBCharacteristic?
    var buffer: [UInt8] = []
    var runtimeSeconds = 300
    var targetID: UUID?
    var sn: String?
    var heartbeatTimer: Timer?
    var sessionStage = 0  // 0=pubExch, 1=keyInfo, 2=authStatus, 3=authResult, 4=live
    var sendSetTime = false
    // Auth secret = MD5hex(your userId + device SN), 32 ASCII chars, sent as the
    // setAuth/checkAuth payload. Never hardcode it: pass --secret or set
    // ECOFLOW_AUTH_SECRET in the environment.
    var authSecret: [UInt8] = ProcessInfo.processInfo.environment["ECOFLOW_AUTH_SECRET"]
        .flatMap { hexBytes($0) } ?? []
    var pendingCommands: [(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8, payload: [UInt8])] = []
    var lastAuthCmd: UInt8 = 0
    var setAuthTries = 0

    func run() {
        central = CBCentralManager(delegate: self, queue: nil)
        let rl = RunLoop.current
        let deadline = Date().addingTimeInterval(TimeInterval(runtimeSeconds + 60))
        while Date() < deadline {
            rl.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[ble] powered on")
            if let id = targetID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(p); return
            }
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff: print("[ble] Bluetooth OFF")
        case .unauthorized: print("[ble] Bluetooth permission DENIED")
        default: print("[ble] state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "?"
        print("[scan] \(name) id=\(peripheral.identifier) rssi=\(RSSI)")
        if name.lowercased().contains("ecoflow") || name.lowercased().contains("r33") {
            central.stopScan(); connect(peripheral)
        }
    }

    func connect(_ p: CBPeripheral) {
        print("[ble] connecting \(p.name ?? "?")")
        peripheral = p; p.delegate = self
        central!.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[ble] connected")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] {
            print("[svc] \(svc.uuid)")
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.notify) { props.append("notify") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            print("  [chr] \(ch.uuid) [\(props.joined(separator: ","))]")
            if (ch.properties.contains(.notify) || ch.properties.contains(.indicate)), notifyChar == nil { notifyChar = ch }
            if (ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)), writeChar == nil { writeChar = ch }
        }
        if let n = notifyChar, service.characteristics?.contains(n) == true {
            p.setNotifyValue(true, for: n)
            print("[ble] subscribed \(n.uuid)")
        }
        tryStartSession()
    }

    func tryStartSession() {
        guard notifyChar != nil, writeChar != nil else { return }
        print("[ble] session starting")
        let frame = hs.startExchange()
        send(frame, label: "pubkey-exchange")
    }

    func send(_ data: Data, label: String) {
        guard let ch = writeChar, let p = peripheral else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxLen = p.maximumWriteValueLength(for: type)
        let chunk = maxLen > 0 ? maxLen : 20
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            p.writeValue(Data(bytes[offset..<end]), for: ch, type: type)
            offset = end
        }
        let line = "[tx] \(label) (\(type == .withResponse ? "wr" : "nr")): \(bytes.map { String(format: "%02x", $0) }.joined())"
        print(line)
        commLog.append(line)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { print("[tx-err] \(e.localizedDescription)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        let bytes = [UInt8](data)
        buffer += bytes
        print("[rx-raw] \(bytes.count)B: \(bytes.prefix(40).map { String(format: "%02x", $0) }.joined())")

        guard let parsed = SessionHandshake.parseV4Frame(buffer, key: hs.sessionKey, iv: hs.aesIv) else {
            if buffer.count > 4096 { buffer.removeFirst(2048) }
            return
        }
        buffer.removeFirst(parsed.consumed)
        let (payload, encrypted, _) = parsed
        guard !payload.isEmpty else { return }
        print("[rx] enc=\(encrypted) len=\(payload.count): \(payload.prefix(48).map { String(format: "%02x", $0) }.joined())")
        commLog.append("[rx] enc=\(encrypted) len=\(payload.count): \(payload.prefix(48).map { String(format: "%02x", $0) }.joined())")

        switch sessionStage {
        case 0:
            if payload[0] == 0x01, payload.count >= 43 {
                if let next = hs.onPubKeyResponse(payload) {
                    sessionStage = 1
                    send(next, label: "getKeyInfoReq")
                }
            }
        case 1:
            if payload[0] == 0x02, payload.count >= 17 {
                if hs.onKeyInfoResponse(payload) {
                    sessionStage = 2
                    print("[session] ESTABLISHED — sessionKey = MD5(login_key[seed0*16+(seed1-1)*256] || sRand)[0:16]")
                    print("[hs] sessionKey:", hs.sessionKey.map { String(format: "%02x", $0) }.joined())
                    // app flow (verified): getAuthStatus as an AA-frame
                    let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x89,
                                                              payload: [], ctr: 0, ctr2: 0,
                                                              key: hs.sessionKey, iv: hs.aesIv)
                    send(f, label: "getAuthStatus-aa")
                }
            }
        case 2:
            if let aa = SessionHandshake.parseAaFrame(payload) {
                print("[auth-ack] src=0x\(String(format: "%02x", aa.src)) dst=0x\(String(format: "%02x", aa.dst)) cmd=0x\(String(format: "%02x", aa.cmdFunc))/0x\(String(format: "%02x", aa.cmdId)) payload=\(aa.payload.map { String(format: "%02x", $0) }.joined())")
                let authed = aa.payload.count >= 1 && aa.payload[0] == 1
                let omos = aa.payload.count >= 2 && aa.payload[1] == 1
                print("[auth] authed=\(authed) omos=\(omos)")
                sessionStage = 3
                let secret = authSecret
                let cmdId: UInt8 = authed ? 0x86 : 0x85
                lastAuthCmd = cmdId
                let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: cmdId,
                                                          payload: secret, ctr: 0, ctr2: 0,
                                                          key: hs.sessionKey, iv: hs.aesIv)
                send(f, label: cmdId == 0x86 ? "checkAuth-aa" : "setAuth-aa")
            } else {
                print("[auth] not an aa-frame: \(payload.map { String(format: "%02x", $0) }.joined().prefix(80))")
            }
        case 3:
            if let aa = SessionHandshake.parseAaFrame(payload) {
                if aa.cmdFunc == 0x35 {
                    // auth-command response (0x35/0x85 setAuth, 0x35/0x86 checkAuth)
                    print("[auth-resp] cmd=0x\(String(format: "%02x", aa.cmdId)) payload=\(aa.payload.map { String(format: "%02x", $0) }.joined())")
                    switch aa.cmdId {
                    case 0x85:
                        if aa.payload.first == 0 {
                            // setAuth accepted — the app then ends auth; we also send
                            // checkAuth (the device starts its telemetry stream after it)
                            print("[auth] setAuth OK — sending checkAuth")
                            let secret = authSecret
                            let f = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x86,
                                                                      payload: secret, ctr: 0, ctr2: 0,
                                                                      key: hs.sessionKey, iv: hs.aesIv)
                            send(f, label: "checkAuth-aa")
                        } else {
                            print("[auth] setAuth FAILED code: \(aa.payload.map { String(format: "%02x", $0) }.joined())")
                        }
                    case 0x86:
                        if aa.payload.first == 0 {
                            print("[auth] checkAuth OK")
                        } else {
                            print("[auth] checkAuth code \(aa.payload.map { String(format: "%02x", $0) }.joined()) — device streams regardless, proceeding")
                        }
                        enterLive()
                    default:
                        if aa.payload.first == 0 { enterLive() }
                    }
                } else {
                    // device already streaming telemetry — go live and use this frame
                    print("[auth] device is streaming — entering live mode")
                    enterLive()
                    emitDataFrame(src: aa.src, dst: aa.dst, cmdFunc: aa.cmdFunc, cmdId: aa.cmdId,
                                  payload: aa.payload, len: aa.len, seq: aa.seq,
                                  obfuscated: aa.obfuscated, crcOk: aa.crcOk)
                }
            } else {
                print("[auth-resp] raw: \(payload.map { String(format: "%02x", $0) }.joined().prefix(80))")
            }
        case 4:
            if let aa = SessionHandshake.parseAaFrame(payload) {
                emitDataFrame(src: aa.src, dst: aa.dst, cmdFunc: aa.cmdFunc, cmdId: aa.cmdId,
                              payload: aa.payload, len: aa.len, seq: aa.seq,
                              obfuscated: aa.obfuscated, crcOk: aa.crcOk)
            } else {
                print("[RX] raw: \(payload.map { String(format: "%02x", $0) }.joined().prefix(120))")
            }
        default: break
        }
        if buffer.count > 4096 { buffer.removeFirst(2048) }
    }

    // Semantic decoding — definitive field map from the app's own parser chain
    // (kt.a "MR330BleCallBack" → eu.t "MR330ParseHelper" → Direct*HeartbeatPack).
    // See TELEMETRY-MAP.md. All offsets verified against 2 live captures.
    func decodeTelemetry(src: UInt8, cmdFunc: UInt8, cmdId: UInt8, payload: [UInt8]) {
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
            print("  [BMS] soc=\(soc.map { String(format: "%.1f%%", $0) } ?? "?")"
                  + " chgVol=\(String(format: "%.3fV", Double(u16(3)) / 1000))"
                  + " paraMin=\(String(format: "%.3fV", Double(u16(35)) / 1000))"
                  + " paraMax=\(String(format: "%.3fV", Double(u16(39)) / 1000))"
                  + " lcdSoc=\(payload[14])%")
        case (0x03, 0x20, 0x32) where payload.count >= 69:   // BMS detailed 188B = DirectBmsMDeltaHeartbeatPack
            let soc = f32(53).map { $0 / 256.0 }
            let v = Double(u16(12)) / 1000
            // the firmware marks unused 32-bit fields with 0x04040404
            func val32(_ i: Int) -> String {
                let x = u32(i)
                return x == 0x04040404 ? "-" : String(x)
            }
            // current: real value sits in the low i16 when the high half is 04 04
            let ampStr: String
            if payload[18] == 0x04 && payload[19] == 0x04 {
                ampStr = String(format: "%.2fA", Double(Int16(bitPattern: u16(16))) / 1000)
            } else {
                ampStr = String(format: "%.2fA", Double(Int32(bitPattern: u32(16))) / 1000)
            }
            print("  [BMS] soc=\(soc.map { String(format: "%.1f%%", $0) } ?? "?")"
                  + " packV=\(String(format: "%.3fV", v))"
                  + " amp=\(ampStr)"
                  + " temp=\(payload[20])°C cycles=\(val32(34))"
                  + " inW=\(val32(57)) outW=\(val32(61))"
                  + " remainMin=\(val32(65))")
        case (0x04, 0x20, 0x02) where payload.count >= 45:   // INV heartbeat 70B = DirectInvDeltaHeartbeatPack
            print("  [INV] inW=\(u16(9)) outW=\(u16(11))"
                  + " outTemp=\(payload[32])°C fanState=\(payload[42])"
                  + " xboost=\(payload[44])")
        case (0x03, 0x03, 0x0e) where payload.count >= 5:    // sub-pack info 83B
            let count = Int(u16(3))
            var i = 5
            print("  [PACKS] count=\(count)")
            var n = 0
            while i + 39 <= payload.count && n < count {
                let snBytes = Array(payload[(i+1)...(i+16)])
                let sn = String(bytes: snBytes.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .utf8) ?? ""
                print("    pack\(n): sn=\(sn)")
                i += 39; n += 1
            }
        case (0x05, 0x20, 0x02) where payload.count >= 73:   // MPPT heartbeat 121B
            // classic DirectMpptHeartbeatPack layout; inVol in 0.01 V units
            print("  [MPPT] inVol=\(String(format: "%.2fV", Double(u16(8) | (UInt16(payload[10]) << 16) | (UInt16(payload[11]) << 24)) / 100.0))"
                  + " inW=\(u16(16)) outW=\(u16(26))"
                  + " mpptTemp=\(u16(28)) chgState=\(payload[33])"
                  + " cfgAc=\(payload[71]) xboost=\(payload[72])")
        default:
            break
        }
    }

    // Transition to live mode exactly once: heartbeats, SET RTC (the app does
    // this on every connect), then any user commands from the CLI.
    func enterLive() {
        guard sessionStage != 4 else { return }
        sessionStage = 4
        print("[auth] SUCCESS — authenticated! heartbeats + data stream")
        startHeartbeat()
        sendRtcCommand()
        if sendSetTime { sendRtcCommand() }
        for c in pendingCommands {
            sendCommand(src: c.src, dst: c.dst, cmdFunc: c.cmdFunc,
                        cmdId: c.cmdId, payload: c.payload, label: "user-cmd")
        }
    }

    func emitDataFrame(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                       payload: [UInt8], len: UInt16, seq: UInt16,
                       obfuscated: Bool, crcOk: Bool) {
        let obf = obfuscated ? " OBFUSCATED(decoded)" : ""
        print("[DATA] src=0x\(String(format: "%02x", src)) dst=0x\(String(format: "%02x", dst)) cmd=0x\(String(format: "%02x", cmdFunc))/0x\(String(format: "%02x", cmdId)) len=\(len) seq=0x\(String(format: "%04x", seq)) crc=\(crcOk ? "ok" : "BAD")\(obf)")
        print("[DATA] payload=\(payload.map { String(format: "%02x", $0) }.joined())")
        decodeTelemetry(src: src, cmdFunc: cmdFunc, cmdId: cmdId, payload: payload)
    }

    func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            guard let self = self, self.sessionStage >= 4 else { return }
            // verified app heartbeat: aa 02 00 00 b50d0000 00000000 21 02 20 59
            let enc = SessionHandshake.buildAaEncrypted(src: 0x21, dst: 0x02, cmdFunc: 0x20, cmdId: 0x59,
                                                        payload: [], ctr: 0, ctr2: 0,
                                                        key: hs.sessionKey, iv: hs.aesIv)
            self.send(enc, label: "heartbeat-aa")
        }
    }

    // Send a control command as an encrypted session AA-frame (src 0x21 = app).
    func sendCommand(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                     payload: [UInt8], label: String) {
        let enc = SessionHandshake.buildAaEncrypted(src: src, dst: dst, cmdFunc: cmdFunc,
                                                    cmdId: cmdId, payload: payload,
                                                    ctr: 0, ctr2: 0,
                                                    key: hs.sessionKey, iv: hs.aesIv)
        send(enc, label: label)
    }

    // SET RTC — payload format verified from the app's own live session:
    //   u16 year LE, month, day, hour, minute, second, ISO weekday (Mon=1..Sun=7)
    // frame: aa 02 08 00 <crc8> 0d 00000000 0000 21 03 03 40 <8B> <crc16>
    func sendRtcCommand() {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let y = cal.component(.year, from: now)
        let mo = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        let h = cal.component(.hour, from: now)
        let mi = cal.component(.minute, from: now)
        let s = cal.component(.second, from: now)
        // ISO weekday: Monday=1 .. Sunday=7
        let sunBased = cal.component(.weekday, from: now)   // Sunday=1..Saturday=7
        let isoWeekday = (sunBased + 5) % 7 + 1
        let payload: [UInt8] = [UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF),
                                UInt8(mo), UInt8(d), UInt8(h), UInt8(mi), UInt8(s), UInt8(isoWeekday)]
        print("[cmd] SET RTC -> \(y)-\(mo)-\(d) \(h):\(mi):\(s) wk=\(isoWeekday)")
        sendCommand(src: 0x21, dst: 0x03, cmdFunc: 0x03, cmdId: 0x40,
                    payload: payload, label: "set-rtc")
    }
}

// simple protobuf wire-format decoder
func decodeProtoFields(_ data: [UInt8]) -> [(Int, String, String)] {
    var out: [(Int, String, String)] = []
    var i = 0
    while i < data.count {
        var key: UInt64 = 0; var shift: UInt64 = 0; var ok = false
        while i < data.count {
            let b = data[i]; i += 1
            key |= UInt64(b & 0x7F) << shift; shift += 7
            if b & 0x80 == 0 { ok = true; break }
        }
        guard ok else { break }
        let field = Int(key >> 3), wt = Int(key & 7)
        switch wt {
        case 0:
            var v: UInt64 = 0; shift = 0; ok = false
            while i < data.count {
                let b = data[i]; i += 1
                v |= UInt64(b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { ok = true; break }
            }
            if ok { out.append((field, "varint", "\(v)")) }
        case 2:
            var len: UInt64 = 0; shift = 0; ok = false
            while i < data.count {
                let b = data[i]; i += 1
                len |= UInt64(b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { ok = true; break }
            }
            guard ok, i + Int(len) <= data.count else { i = data.count; break }
            let sub = Array(data[i..<i+Int(len)]); i += Int(len)
            let printable = sub.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0 }
            if printable && sub.contains(where: { $0 >= 0x20 && $0 < 0x7F }) {
                out.append((field, "string", String(bytes: sub, encoding: .utf8) ?? ""))
            } else {
                out.append((field, "bytes(\(sub.count))", sub.prefix(16).map { String(format: "%02x", $0) }.joined()))
            }
        case 5:
            if i + 4 <= data.count {
                let v = UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
                i += 4
                out.append((field, "fixed32", "\(v)"))
            } else { i = data.count }
        case 1:
            if i + 8 <= data.count { i += 8; out.append((field, "fixed64", "...")) }
            else { i = data.count }
        default: i = data.count
        }
    }
    return out
}
