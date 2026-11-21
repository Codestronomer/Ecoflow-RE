// mock-ecoflow.swift — CoreBluetooth PERIPHERAL that impersonates the EcoFlow E980.
//
// We own the device-side ECDH private key, so every encrypted frame the app
// sends is decrypted live. Goal: capture the app's exact auth + data commands
// for productType 80 (E980).
//
// Build:  swiftc -O -o mock-ecoflow mock-ecoflow.swift Secp160.swift SessionHandshake.swift CryptoHelpers.swift
// Run:    ./mock-ecoflow
//
// ADV replicates the real device:
//   Flags 02 01 06 + Manufacturer data (company 0xB5B5):
//     b5b5 13 "<SN>" 5b 0001 0000 3e 4e
//   Service UUID 0x0001, write char 0x0002, notify char 0x0003 (16-bit UUIDs).

import Foundation
import CoreBluetooth
import Security

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func hex1(_ b: UInt8) -> String { String(format: "%02x", b) }

final class MockDevice: NSObject, CBPeripheralManagerDelegate {
    let pm = CBPeripheralManager()
    var service: CBMutableService!
    var writeCh: CBMutableCharacteristic!
    var notifyCh: CBMutableCharacteristic!
    var logHandle: FileHandle?

    // device-side ECDH keypair
    let privKey: Big
    let pubKey: [UInt8]

    var appPub: [UInt8] = []
    var subscribed: [CBCentral] = []
    var share: [UInt8] = []
    var aesKey: [UInt8] = []      // share[0:16]
    var aesIv: [UInt8] = []       // md5(share20)
    var sessionKey: [UInt8] = []  // MD5(login_key[seed] || sRand)[0:16]
    var established = false

    let sRand: [UInt8]
    let seed: [UInt8] = [0x0F, 0x02]

    override init() {
        var pb = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &pb)
        privKey = Big(pb).mod(Curve160.n)
        pubKey = Curve160.publicKey(priv: privKey)
        var sb = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &sb)
        sRand = sb
        super.init()
        pm.delegate = self
    }

    func log(_ s: String) {
        let line = s
        print(line)
        if logHandle == nil {
            let path = "ble/mock-session.log"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            logHandle = FileHandle(forWritingAtPath: path)
            logHandle?.seekToEndOfFile()
        }
        logHandle?.write((line + "\n").data(using: .utf8)!)
    }

    var serviceAdded = false

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            log("[bt] state = \(peripheral.state.rawValue) (5 = poweredOn)")
            return
        }
        log("[bt] powered on")
        if !serviceAdded {
            serviceAdded = true
            log("[mock] devicePub: \(hex(pubKey))")
            log("[mock] sRand: \(hex(sRand)) seed: \(hex(seed))")

            let w = CBMutableCharacteristic(type: CBUUID(string: "0002"),
                                            properties: [.write, .writeWithoutResponse],
                                            value: nil, permissions: [.writeable])
            let n = CBMutableCharacteristic(type: CBUUID(string: "0003"),
                                            properties: [.notify],
                                            value: nil, permissions: [.readable])
            n.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2902"), value: Data([0x00, 0x00]))]
            let s = CBMutableService(type: CBUUID(string: "0001"), primary: true)
            s.characteristics = [w, n]
            service = s; writeCh = w; notifyCh = n
            pm.add(s)
        }

        var mfr = Data([0xb5, 0xb5])  // company id, little-endian on air
        mfr += Data([0x13, 0x52])    // len 0x13, 'R'
        mfr += Data("701ZKB59GCR0001".utf8)  // FAKE unbound SN — the real SN is bound to
                                            // this account and the add-flow skips it
        mfr += Data([0x5b, 0x00, 0x01, 0x00, 0x00, 0x3e, 0x4e])
        mockMfr = mfr
        // ADV matches the real device EXACTLY: flags (auto) + manufacturer data only
        // (31 bytes on air). The earlier reset-loop was caused by re-adding the
        // service on every state change — now guarded by serviceAdded.
        let adv: [String: Any] = [
            CBAdvertisementDataManufacturerDataKey: mfr,
        ]
        pm.startAdvertising(adv)
        log("[adv] startAdvertising requested (mfr only, \(mfr.count)B payload)")
    }

    var mockMfr = Data()

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {}

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        log("[adv] didStartAdvertising error=\(error.map { $0.localizedDescription } ?? "none") isAdvertising=\(peripheral.isAdvertising)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.log("[adv] 3s check: isAdvertising=\(peripheral.isAdvertising)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribed.contains(where: { $0.identifier == central.identifier }) { subscribed.append(central) }
        log("[central] subscribed \(central.identifier)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribed.removeAll { $0.identifier == central.identifier }
        log("[central] unsubscribed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead requests: [CBATTRequest]) {
        for r in requests {
            r.value = Data([0x00, 0x00])
            pm.respond(to: r, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let v = r.value { handle(v) }
            pm.respond(to: r, withResult: .success)
        }
    }

    func send(_ data: Data) {
        let subs = subscribed
        _ = pm.updateValue(data, for: notifyCh, onSubscribedCentrals: subs)
    }

    func sendPlaintext(_ payload: [UInt8]) {
        let f = SessionHandshake.buildPlaintext(payload)
        log("[tx-plain] \(f.map { String(format: "%02x", $0) }.joined())")
        send(f)
    }

    func sendEncrypted(_ body: [UInt8]) {
        guard !sessionKey.isEmpty else { log("[tx] no session key, skip"); return }
        let f = SessionHandshake.buildEncrypted(body, key: sessionKey, iv: aesIv)
        log("[tx-enc] \(f.map { String(format: "%02x", $0) }.joined())")
        send(f)
    }

    func handle(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 0x5A, b[1] == 0x5A else {
            log("[rx-raw] non-frame: \(hex(b))")
            return
        }
        let flags = b[2]
        let len = Int(b[4]) | (Int(b[5]) << 8)
        let total = len + 6
        guard b.count >= total, len >= 2 else {
            log("[rx-raw] partial frame (\(b.count)B): \(hex(b))")
            return
        }
        let body = Array(b[6..<(total - 2)])

        if flags == 0x00 {
            handlePlaintext(body)
        } else if flags == 0x10 {
            handleEncrypted(body)
        } else {
            log("[rx] unknown flags 0x\(hex1(flags)): \(hex(body))")
        }
    }

    func handlePlaintext(_ body: [UInt8]) {
        if body.count >= 42 && body[0] == 0x01 && body[1] == 0x00 {
            appPub = Array(body[2..<(2 + 40)])
            log("[app] appPub: \(hex(appPub))")
            share = Curve160.sharedSecret(priv: privKey, devPub: appPub)
            aesKey = Array(share[0..<16])
            aesIv = [UInt8](md5(Data(share)))
            log("[mock] share: \(hex(share))")
            log("[mock] iv: \(hex(aesIv))")
            // reply: {0x01, 0x00, 0x00, devPub40}
            sendPlaintext([0x01, 0x00, 0x00] + pubKey)
            return
        }
        if body.count == 1 && body[0] == 0x02 {
            // keyInfoReq → reply {0x02, AES(share, iv, sRand||seed PKCS-padded)}
            var plain = sRand + seed
            let pad = 16 - (plain.count % 16)
            plain += [UInt8](repeating: UInt8(pad), count: pad)
            guard let ct = aesCBCEncrypt(plain, key: aesKey, iv: aesIv) else {
                log("[mock] keyInfo encrypt failed"); return
            }
            sessionKey = SessionHandshake.sessionKeyFromSeed(seed: seed, sRand: sRand)
            established = true
            log("[mock] keyInfoReq → replying sRand/seed; sessionKey: \(hex(sessionKey))")
            sendPlaintext([0x02] + Array(ct))
            return
        }
        log("[rx-plain] \(hex(body))")
    }

    func handleEncrypted(_ body: [UInt8]) {
        // try session key first, then share key as fallback
        var inner: [UInt8]? = nil
        var usedKey = "sessionKey"
        if !sessionKey.isEmpty {
            inner = SessionHandshake.decryptBody(body, key: sessionKey, iv: aesIv)
        }
        if (inner == nil || inner?.count == 0), !aesKey.isEmpty {
            inner = SessionHandshake.decryptBody(body, key: aesKey, iv: aesIv)
            usedKey = "shareKey"
        }
        guard let plain = inner, !plain.isEmpty else {
            log("[rx-enc] DECRYPT FAILED ct(\(body.count)): \(hex(body))")
            return
        }
        log("[rx-enc] decrypted with \(usedKey): \(hex(plain))")
        if plain.count >= 8 && plain[0] & 0x20 != 0 {
            let f = plain[0]
            let cf = plain[1], ci = plain[2], seq = plain[3]
            let src = plain[4], srcd = plain[5], dst = plain[6], dstd = plain[7]
            let pl = Array(plain[8...])
            log("[CMD] flags=0x\(hex1(f)) cmdSet=0x\(hex1(cf)) cmdId=0x\(hex1(ci)) seq=\(seq) src=0x\(hex1(src)).\(srcd) dst=0x\(hex1(dst)).\(dstd) payload(\(pl.count))= \(hex(pl))")
            if !pl.isEmpty {
                let fields = decodeProtoFields(pl)
                for (field, kind, val) in fields.prefix(24) {
                    log("      pb \(field) (\(kind)) = \(val)")
                }
            }
            // ACK: echo cmd, is_ack bit, src/dst swapped (device=src 0x35, app=dst 0x21)
            let ackPayload = ackPayloadFor(cmdSet: cf, cmdId: ci)
            let ackBody: [UInt8] = [0x21, cf, ci, seq, 0x35, 0x00, 0x21, 0x00] + ackPayload
            sendEncrypted(ackBody)
        } else {
            log("[rx-enc-inner] not sscmd: \(hex(plain))")
        }
    }

    func ackPayloadFor(cmdSet: UInt8, cmdId: UInt8) -> [UInt8] {
        // getAuthStatus → claim: authed(owner) + OMOS flag=1, driving the app to the
        // OMOS startAuth path (which carries the cached user token!)
        if cmdSet == 0x35 && cmdId == 0x89 { return [0x01, 0x01] }
        if cmdSet == 0x35 && cmdId == 0xA9 { return [0x00] }  // ConfirmBind → ok
        return []
    }
}

// simple protobuf wire-format decoder (same as ecoflow-session.swift)
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

extension Data {
    init(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<next], radix: 16) ?? 0)
            i = next
        }
        self = d
    }
}

@main
struct MockMain {
    static let device = MockDevice()
    static func main() {
        _ = device  // force lazy static init — creates the CBPeripheralManager
        print("mock-ecoflow starting… (log: ble/mock-session.log)")
        let rl = RunLoop.main
        let deadline = Date().addingTimeInterval(60 * 60)  // run 1 hour
        while Date() < deadline {
            rl.run(until: Date().addingTimeInterval(0.5))
        }
        print("mock exiting after 1h")
    }
}
