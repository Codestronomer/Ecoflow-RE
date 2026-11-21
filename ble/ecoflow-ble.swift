// EcoFlow BLE client — macOS CoreBluetooth
// Reconstructed from EcoFlow Android app v6.16.8.24 static analysis:
//   - Frame: 0xAA header [ver, lenLo, lenHi, crc8] + AES-CBC(zero-pad) body + CRC16
//   - Type-1 keys: key = MD5(SN), iv = MD5(reversed SN); AES/CBC/NOPADDING (zero padding)
//   - CRC8: poly 0x07 table-driven init 0; CRC16: reflected poly 0xA001 init 0 (LE bytes)
//   - Body: [0x0D, seq(LE32), 0x00, 0x00, src, dst, (v3: dSrc,dDst), cmdSet, cmdId, payload...]
//   - GATT: service 00000001-... or NUS 6E400001-...; write+notify auto-discovered
// Usage:
//   ecoflow-ble scan [seconds]
//   ecoflow-ble run [--sn <SN>] [--name <prefix>] [--id <peripheralUUID>] [--seconds N]

import Foundation
import CoreBluetooth
import CommonCrypto

// ---------- crypto ----------
func md5(_ data: Data) -> Data {
    var d = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { ptr in
        CC_MD5(ptr.baseAddress, CC_LONG(data.count), &d)
    }
    return Data(d)
}

func aesCBCEncrypt(_ input: Data, key: Data, iv: Data) -> Data? {
    guard key.count == kCCKeySizeAES128 else { return nil }
    var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var outLen = 0
    let status = input.withUnsafeBytes { inPtr in
        key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), // CBC, no padding
                        kPtr.baseAddress, kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        inPtr.baseAddress, input.count,
                        &out, out.count, &outLen)
            }
        }
    }
    return status == kCCSuccess ? Data(out.prefix(outLen)) : nil
}

func aesCBCDecrypt(_ input: Data, key: Data, iv: Data) -> Data? {
    guard key.count == kCCKeySizeAES128, input.count % 16 == 0, !input.isEmpty else { return nil }
    var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var outLen = 0
    let status = input.withUnsafeBytes { inPtr in
        key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),
                        kPtr.baseAddress, kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        inPtr.baseAddress, input.count,
                        &out, out.count, &outLen)
            }
        }
    }
    return status == kCCSuccess ? Data(out.prefix(outLen)) : nil
}

// ---------- CRC ----------
let crc8Tab: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt8(i)
        for _ in 0..<8 {
            c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1
        }
        t[i] = c
    }
    return t
}()

func crc8(_ data: [UInt8]) -> UInt8 {
    var c: UInt8 = 0
    for b in data { c = crc8Tab[Int(c ^ b)] }
    return c
}

let crc16Tab: [UInt16] = {
    var t = [UInt16](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt16(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1
        }
        t[i] = c
    }
    return t
}()

func crc16(_ data: [UInt8]) -> UInt16 {
    var c: UInt16 = 0
    for b in data { c = crc16Tab[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
    return c
}

// ---------- proto helpers (wire format only) ----------
func protoTag(_ field: Int, _ wireType: Int) -> [UInt8] {
    var key = UInt32((field << 3) | wireType)
    var out: [UInt8] = []
    while true {
        if key < 0x80 { out.append(UInt8(key)); break }
        out.append(UInt8((key & 0x7F) | 0x80)); key >>= 7
    }
    return out
}
func protoVarint(_ field: Int, _ v: UInt64) -> [UInt8] {
    var out = protoTag(field, 0); var x = v
    while true {
        if x < 0x80 { out.append(UInt8(x)); break }
        out.append(UInt8((x & 0x7F) | 0x80)); x >>= 7
    }
    return out
}
func protoBool(_ field: Int, _ v: Bool) -> [UInt8] { protoVarint(field, v ? 1 : 0) }

// decode a protobuf message generically for logging
func protoDecodeFields(_ data: [UInt8]) -> [(Int, String, String)] {
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
        case 1:
            if i + 8 <= data.count {
                let bytes = Array(data[i..<i+8]); i += 8
                let lo = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                let hi = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                out.append((field, "fixed64", "\(UInt64(hi) << 32 | UInt64(lo))"))
            } else { i = data.count }
        case 2:
            var len: UInt64 = 0; shift = 0; ok = false
            while i < data.count {
                let b = data[i]; i += 1
                len |= UInt64(b & 0x7F) << shift; shift += 7
                if b & 0x80 == 0 { ok = true; break }
            }
            guard ok, i + Int(len) <= data.count else { i = data.count; break }
            let sub = Array(data[i..<i+Int(len)]); i += Int(len)
            let printable = sub.allSatisfy { $0 >= 0x20 && $0 < 0x7F || $0 == 0 }
            if printable && sub.contains(where: { $0 >= 0x20 && $0 < 0x7F }) {
                out.append((field, "string", String(bytes: sub, encoding: .utf8) ?? ""))
            } else if let nested = try? protoDecodeFields(sub), nested.count > 0, sub.count < 200 {
                let s = nested.prefix(8).map { "\($0.0):\($0.2)" }.joined(separator: ",")
                out.append((field, "msg(\(sub.count)B)", "{\(s)}"))
            } else {
                out.append((field, "bytes(\(sub.count))", sub.prefix(16).map { String(format: "%02x", $0) }.joined()))
            }
        case 5:
            if i + 4 <= data.count {
                let bytes = Array(data[i..<i+4]); i += 4
                let v = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                out.append((field, "fixed32", "\(v)"))
            } else { i = data.count }
        default:
            i = data.count
        }
    }
    return out
}

// ---------- protocol framing ----------
struct EcoFrame {
    var version: Int
    var seq: Int
    var src: UInt8, dst: UInt8
    var dSrc: UInt8, dDst: UInt8   // valid when version >= 3
    var cmdSet: UInt8, cmdId: UInt8
    var payload: [UInt8]
    var active: Bool

    func describe() -> String {
        var s = "v\(version) seq=\(seq) src=\(src) dst=\(dst)"
        if version >= 3 { s += " dSrc=\(dSrc) dDst=\(dDst)" }
        s += " cmdSet=\(cmdSet)(0x\(String(cmdSet, radix: 16))) cmdId=\(cmdId)(0x\(String(cmdId, radix: 16)))"
        s += " len=\(payload.count) \(active ? "PUSH" : "RESP")"
        return s
    }
}

final class EcoCodec {
    let key: Data, iv: Data
    private var seqCounter: UInt32 = 0
    init(sn: String) {
        key = md5(Data(sn.utf8))
        let rev = String(sn.reversed())
        iv = md5(Data(rev.utf8))
        print("[codec] key=\(key.map { String(format: "%02x", $0) }.joined()) iv=\(iv.map { String(format: "%02x", $0) }.joined())")
    }

    func build(_ dst: UInt8, cmdSet: UInt8, cmdId: UInt8, payload: [UInt8],
               src: UInt8 = 33, version: Int = 2, dSrc: UInt8 = 0, dDst: UInt8 = 0, encrypted: Bool = true) -> Data? {
        seqCounter &+= 1
        let seq = seqCounter
        var body: [UInt8] = [0x0D]
        body.append(UInt8(seq & 0xFF))
        body.append(UInt8((seq >> 8) & 0xFF))
        body.append(UInt8((seq >> 16) & 0xFF))
        body.append(UInt8((seq >> 24) & 0xFF))
        body.append(0x00); body.append(0x00)
        body.append(src); body.append(dst)
        if version >= 3 { body.append(dSrc); body.append(dDst) }
        body.append(cmdSet); body.append(cmdId)
        body.append(contentsOf: payload)
        // CRC16 over header(5) + body
        let len = payload.count
        var header: [UInt8] = [0xAA, UInt8(version), UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)]
        header.append(crc8(header))
        var crcInput = header + body
        let c = crc16(crcInput)
        crcInput.append(UInt8(c & 0xFF)); crcInput.append(UInt8((c >> 8) & 0xFF))
        if !encrypted {
            return Data(header) + Data(crcInput)   // plaintext variant (encryptType 0)
        }
        // zero-pad to 16
        while crcInput.count % 16 != 0 { crcInput.append(0x00) }
        guard let cipher = aesCBCEncrypt(Data(crcInput), key: key, iv: iv) else { return nil }
        return Data(header) + cipher
    }

    /// Parse a byte stream (accumulated notifications) into frames; returns (frames, consumed)
    func parse(_ buffer: [UInt8]) -> (frames: [EcoFrame], consumed: Int) {
        var frames: [EcoFrame] = []
        var pos = 0
        while true {
            // find header 0xAA or 0x5A
            guard let start = buffer[pos...].firstIndex(where: { $0 == 0xAA || $0 == 0x5A }) else {
                return (frames, buffer.count)
            }
            pos = start
            guard buffer.count - pos >= 5 else { return (frames, start) }
            let isOdm = buffer[pos] == 0x5A
            let ver = Int(buffer[pos+1])
            let payLen = Int(buffer[pos+2]) | Int(buffer[pos+3]) << 8
            let expectCrc8 = buffer[pos+4]
            let hdr = Array(buffer[pos..<pos+4])
            guard crc8(hdr) == expectCrc8 else {
                pos += 1; continue
            }
            let bodySize = (ver >= 3 ? 13 : 11) + payLen
            // ciphertext length: AES frames zero-pad (body+crc16) to 16; plaintext adds crc16 unaligned
            let cipherLen = payLen == 0 && bodySize + 2 <= 16 ? 16 : ((bodySize + 2 + 15) / 16) * 16
            let plainLen = bodySize + 2
            let haveBytes = buffer.count - pos - 5
            let frameLen = cipherLen   // assume encrypted framing; plaintext frames are a strict subset length-wise
            guard haveBytes >= min(frameLen, plainLen) else {
                return (frames, start)  // incomplete — wait for more
            }
            func decode(cipherBytes: [UInt8], tryPlainAlso: Bool) -> EcoFrame? {
                var candidates: [Data] = []
                if let dec = aesCBCDecrypt(Data(cipherBytes), key: key, iv: iv) { candidates.append(dec) }
                if tryPlainAlso && cipherBytes.count == plainLen { candidates.append(Data(cipherBytes)) }
                for plain0 in candidates {
                    var p = [UInt8](plain0)
                    for strip in 0..<16 {
                        guard p.count >= strip + 2 else { break }
                        let body = Array(p[0..<(p.count - strip - 2)])
                        let cStored = UInt16(p[p.count - strip - 2]) | (UInt16(p[p.count - strip - 1]) << 8)
                        if crc16(hdr + body) != cStored { continue }
                        guard body.count >= 11, body[0] == 0x0D else { break }
                        let seq = Int(body[1]) | Int(body[2]) << 8 | Int(body[3]) << 16 | Int(body[4]) << 24
                        let src = body[7], dst = body[8]
                        var idx = 9
                        var dSrc: UInt8 = 0, dDst: UInt8 = 0
                        if ver >= 3 { dSrc = body[idx]; dDst = body[idx+1]; idx += 2 }
                        guard body.count > idx + 1 else { break }
                        let cmdSet = body[idx], cmdId = body[idx+1]
                        let payload = Array(body[(idx+2)..<body.count])
                        return EcoFrame(version: ver, seq: seq, src: src, dst: dst, dSrc: dSrc, dDst: dDst,
                                        cmdSet: cmdSet, cmdId: cmdId, payload: payload,
                                        active: isActivePush(src: src, dst: dst, dSrc: dSrc, dDst: dDst,
                                                             cmdSet: cmdSet, cmdId: cmdId))
                    }
                }
                return nil
            }
            var frame: EcoFrame? = nil
            var end = pos + 5 + cipherLen
            if haveBytes >= plainLen {
                // plaintext framing first (encryptType 0 — unbound devices)
                let plainBytes = Array(buffer[(pos+5)..<(pos+5+plainLen)])
                frame = decode(cipherBytes: plainBytes, tryPlainAlso: true)
                if frame != nil { end = pos + 5 + plainLen }
            }
            if frame == nil && haveBytes >= cipherLen && cipherLen != plainLen {
                let cipher = Array(buffer[(pos+5)..<(pos+5+cipherLen)])
                frame = decode(cipherBytes: cipher, tryPlainAlso: false)
                end = pos + 5 + cipherLen
            }
            if let f = frame {
                frames.append(f)
                pos = end
            } else {
                pos = start + 1
            }
        }
    }

    // DefaultEcoPacketActiveChecker (condensed): device-initiated push signatures
    private func isActivePush(src: UInt8, dst: UInt8, dSrc: UInt8, dDst: UInt8,
                              cmdSet: UInt8, cmdId: UInt8) -> Bool {
        let s = Int(src), d = Int(dst), cs = Int(cmdSet), ci = Int(cmdId)
        if s == 53 && cs == 53 && (ci == 32 || ci == 14 || ci == 113 || ci == 17 || ci == 67) { return true }
        if d == 33 && cs == 69 && (ci == 23 || ci == 39) { return true }
        if s == 66 && cs == 66 && ci == 80 { return true }
        if s == 33 && cs == 11 { return true }
        if s == 8 && cs == 32 && ci == 2 { return true }
        if s == 11 && cs == 12 && (ci == 32 || ci == 1 || ci == 80) { return true }
        if cs == 254 && (ci == 32 || ci == 16) { return true }
        if s == 53 && cs == 1 && ci == 82 { return true }
        if s == 2 && cs == 32 && (ci == 64 || ci == 89) { return true }
        if s == 2 && cs == 2 && (ci == 1 || ci == 3 || ci == 4) { return true }
        if s == 66 && d == 33 && cs == 32 && ci == 1 { return true }
        if s == 66 && cs == 32 && ci == 50 { return true }
        if s == 53 && dDst == 0 && dSrc == 0 && d == 33 && (cs == 32 || cs == 2) &&
            (ci == 1 || ci == 22 || ci == 27) { return true }
        if s == 53 && d == 33 && cs == 2 && (ci == 1 || ci == 2 || ci == 32 || ci == 133 || ci == 135) { return true }
        if s == 53 && d == 33 && cs == 20 && (ci == 1 || ci == 32 || ci == 134 || ci == 136) { return true }
        if s == 53 && d == 33 && (cs == 2 || cs == 32) && ci == 98 { return true }
        if s == 50 && d == 50 && ci == 7 { return true }
        if s == 3 && cs == 3 && (ci == 14 || ci == 26 || ci == 28) { return true }
        if s == 8 && cs == 254 && ci == 21 { return true }
        if (s == 3 || s == 6) && cs == 32 && ci == 88 { return true }
        if cs == 32 && ci == 177 { return true }
        if s == 5 && cs == 5 && ci == 32 { return true }
        if (s == 80 && cs == 80 && ci == 32) || (s == 81 && cs == 81 && ci == 32) { return true }
        if s == 83 && cs == 83 && ci == 32 { return true }
        if s == 84 && cs == 84 && ci == 32 { return true }
        if cs == 8 && ci == 16 { return true }
        if s == 55 && cs == 55 && (ci == 32 || ci == 51) { return true }
        if s == 18 && cs == 18 && ci == 10 { return true }
        if s == 57 && cs == 57 && ci == 80 { return true }
        if s == 66 && cs == 3 && ci == 9 { return true }
        if s == 8 && cs == 3 && ci == 9 { return true }
        if s == 33 && cs == 53 && ci == 114 { return true }
        if s == 20 && cs == 20 { return true }
        if (s == 96 || s == 11) && cs == 254 && (ci == 21 || ci == 22 || ci == 25) { return true }
        if cs == 240 && (ci == 4 || ci == 2) { return true }
        return false
    }
}

// ---------- BLE manager ----------
final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var codec: EcoCodec?
    var writeChar: CBCharacteristic?
    var notifyChar: CBCharacteristic?
    var buffer: [UInt8] = []
    var runtimeSeconds = 600
    var targetName: String?
    var targetID: UUID?
    var sn: String?
    var seq = 0
    var heartbeatTimer: Timer?
    var gotSN: ((String) -> Void)?

    let serviceCandidates = [
        CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb"),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "0000ffff-0000-1000-8000-00805f9b34fb"),
        CBUUID(string: "0000fff0-0000-1000-8000-00805f9b34fb"),
    ]

    func run() {
        central = CBCentralManager(delegate: self, queue: nil)
        let rl = RunLoop.current
        let deadline = Date().addingTimeInterval(TimeInterval(runtimeSeconds + 60))
        while Date() < deadline && rl.run(mode: .default, before: Date().addingTimeInterval(0.2)) {}
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[ble] powered on")
            if let id = targetID {
                if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                    connect(p)
                    return
                }
            }
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            print("[ble] scanning...")
        case .poweredOff: print("[ble] Bluetooth is OFF — enable it and rerun")
        case .unauthorized: print("[ble] Bluetooth permission DENIED — allow this terminal app in System Settings > Privacy & Security > Bluetooth, then rerun")
        default: print("[ble] state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(unnamed)"
        let svc = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        print("[scan] \(name)  id=\(peripheral.identifier)  rssi=\(RSSI)  svc=\(svc)  mfg=\(mfg)")
        guard let want = targetName else { return }
        if name.lowercased().contains(want.lowercased()) {
            central.stopScan()
            connect(peripheral)
        }
    }

    func connect(_ p: CBPeripheral) {
        print("[ble] connecting to \(p.name ?? p.identifier.uuidString)")
        peripheral = p
        p.delegate = self
        central!.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[ble] connected — discovering services")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] {
            let interesting = serviceCandidates.contains(svc.uuid) ? " << candidate" : ""
            print("[svc] \(svc.uuid)\(interesting)")
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("[chars] service \(service.uuid)")
        for ch in service.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.notify) { props.append("notify") }
            if ch.properties.contains(.indicate) { props.append("indicate") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if ch.properties.contains(.read) { props.append("read") }
            print("  [chr] \(ch.uuid)  [\(props.joined(separator: ","))]")
            if (ch.properties.contains(.notify) || ch.properties.contains(.indicate)), notifyChar == nil {
                notifyChar = ch
            }
            if (ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)), writeChar == nil {
                writeChar = ch
            }
        }
        if service.uuid.uuidString.lowercased().hasPrefix("6e400001") ||
           service.uuid == CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb") {
            if let n = notifyChar, service.characteristics?.contains(n) == true {
                peripheral.setNotifyValue(true, for: n)
                print("[ble] subscribing notify: \(n.uuid)")
            }
        }
        tryStartSession()
    }

    func tryStartSession() {
        guard notifyChar != nil, writeChar != nil, peripheral != nil else { return }
        print("[ble] session starting (write=\(writeChar!.uuid) notify=\(notifyChar!.uuid))")
        if let sn = sn {
            codec = EcoCodec(sn: sn)
            startProbes()
        } else {
            print("[ble] no SN yet — will request device SN over BLE")
            // unencrypted probe impossible for encrypted frames; type-1 needs SN.
            // Try common default: some devices answer plaintext 0x5A frames.
            startProbes()
        }
    }

    func startProbes() {
        // Exact app bootstrap frame (BleAuthCommand.getAuthStatus, V3 device):
        // src=33, dst=53, cmdSet=53, cmdId=0x89, payload=EMPTY, ver=3, dSrc=1, dDst=1, plaintext
        if let f = codec?.build(53, cmdSet: 53, cmdId: 0x89, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "auth-status-probe-v3")
        }
        // V2 variant (older firmware path)
        if let f = codec?.build(53, cmdSet: 53, cmdId: 0x89, payload: [], encrypted: false) {
            send(f, label: "auth-status-probe-v2")
        }
        // dst=50 variant (productType 14/82 devices)
        if let f = codec?.build(50, cmdSet: 53, cmdId: 0x89, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "auth-status-probe-v3-dst50")
        }
        // get SN info: dst=53, cmdSet=53, cmdId=65 (plaintext V3)
        if let f = codec?.build(53, cmdSet: 53, cmdId: 65, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "get-sn-info")
        }
        // start bind (S1_IOT_CMD_ID_START_BIND 0xA8): dst=53, cmdSet=53
        if let f = codec?.build(53, cmdSet: 53, cmdId: 0xA8, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "start-bind")
        }
        // product info: dst=1, cmdSet=1, cmdId=5
        if let f = codec?.build(1, cmdSet: 1, cmdId: 5, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "product-info")
        }
        // request full display property upload: dst=2, cmdSet=0xFE, cmdId=17, ConfigWrite{6:utc, 71:true}
        let utc = UInt32(Date().timeIntervalSince1970)
        var payload = protoVarint(6, UInt64(utc)) + protoBool(71, true)
        if let f = codec?.build(2, cmdSet: 0xFE, cmdId: 17, payload: payload, version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "full-upload-request")
        }
        // heartbeat: dst=2, cmdSet=32, cmdId=2 (V3 plaintext)
        if let f = codec?.build(2, cmdSet: 32, cmdId: 2, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
            send(f, label: "heartbeat")
        }
        var probeTick = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            probeTick += 1
            if let f = self.codec?.build(2, cmdSet: 32, cmdId: 2, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
                self.send(f, label: "heartbeat")
            }
            if probeTick % 2 == 1, let f = self.codec?.build(53, cmdSet: 53, cmdId: 0x89, payload: [], version: 3, dSrc: 1, dDst: 1, encrypted: false) {
                self.send(f, label: "auth-status-probe-v3")
            }
            if probeTick % 6 == 1, let f = self.codec?.build(2, cmdSet: 0xFE, cmdId: 17,
                    payload: protoVarint(6, UInt64(UInt32(Date().timeIntervalSince1970))) + protoBool(71, true), version: 3, dSrc: 1, dDst: 1, encrypted: false) {
                self.send(f, label: "full-upload-request")
            }
        }
    }

    func send(_ data: Data, label: String) {
        guard let ch = writeChar, let p = peripheral else { return }
        let useNoResp = ch.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = useNoResp ? .withoutResponse : .withResponse
        let maxLen = p.maximumWriteValueLength(for: type)
        let chunk = maxLen > 0 ? maxLen : 20
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            p.writeValue(Data(bytes[offset..<end]), for: ch, type: type)
            offset = end
        }
        print("[tx] \(label) (\(type == .withResponse ? "withResp" : "noResp")): \(bytes.map { String(format: "%02x", $0) }.joined())")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { print("[tx-err] \(characteristic.uuid): \(e.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, peripheralIsReady toSendWriteWithoutResponse: Bool) {
        // no-op: writes are queued synchronously
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        buffer.append(contentsOf: bytes)
        print("[rx-raw] \(bytes.count)B: \(bytes.map { String(format: "%02x", $0) }.joined())")
        guard let codec = codec else {
            if buffer.count > 256 { buffer.removeFirst(buffer.count - 256) }
            return
        }
        let (frames, consumed) = codec.parse(buffer)
        if consumed == 0 && buffer.count > 512 {
            // unparseable garbage — keep last 256B and log
            print("[rx-drop] buffer \(buffer.count)B unparsed")
            buffer.removeFirst(buffer.count - 256)
            return
        }
        buffer.removeFirst(consumed)
        for f in frames {
            let hex = f.payload.prefix(48).map { String(format: "%02x", $0) }.joined()
            print("[rx] \(f.describe())")
            print("      payload: \(hex)\(f.payload.count > 48 ? "..." : "")")
            if let fields = try? protoDecodeFields(f.payload), !fields.isEmpty, f.payload.count > 2 {
                for (field, kind, value) in fields.prefix(24) {
                    print("      pb field \(field) (\(kind)) = \(value)")
                }
            }
        }
        if buffer.count > 4096 { buffer.removeFirst(1024) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { print("[ble] subscribe failed: \(e.localizedDescription)") }
    }
}

// ---------- main ----------
var args = Array(CommandLine.arguments.dropFirst())
let client = Client()

// double-clicked app bundle: no args → default run session
if args.isEmpty {
    args = ["run", "--sn", "<SN>",
            "--id", "<PERIPHERAL_UUID>",
            "--seconds", "300",
            "--logfile", "ble/ecoflow-run.log"]
}

// optional logfile redirection (for bundled/app launches)
if let li = args.firstIndex(of: "--logfile"), li + 1 < args.count {
    let path = args[li + 1]
    _ = FileManager.default.createFile(atPath: path, contents: nil)
    if let fh = FileHandle(forWritingAtPath: path) {
        dup2(fh.fileDescriptor, 1); dup2(fh.fileDescriptor, 2); setbuf(stdout, nil)
    }
}

if args.first == "scan" {
    client.runtimeSeconds = args.count > 1 ? Int(args[1]) ?? 15 : 15
    print("scanning \(client.runtimeSeconds)s — power on the device, keep it near")
} else if args.first == "run" {
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--sn": i += 1; client.sn = args[i]
        case "--name": i += 1; client.targetName = args[i]
        case "--id": i += 1; client.targetID = UUID(uuidString: args[i])
        case "--seconds": i += 1; client.runtimeSeconds = Int(args[i]) ?? 600
        default: break
        }
        i += 1
    }
    client.runtimeSeconds = max(client.runtimeSeconds, 60)
} else {
    print("usage: ecoflow-ble scan [seconds] | run [--sn SN] [--name prefix] [--id UUID] [--seconds N] [--logfile path]")
    exit(0)
}
client.run()
