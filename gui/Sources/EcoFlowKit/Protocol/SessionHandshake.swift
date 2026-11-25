// EcoFlow session handshake — implements the decoded V4 session-key exchange:
//   1. secp160r1 ECDH (curve type 0): pub = {0x01, 0x00, pub40}
//   2. device returns {0x01, 0x00, 0x00, devPub40}
//   3. share = X(priv*devPub) 20B; aesKey = share[0:16]; aesIv = MD5(share[0:20])
//   4. getKeyInfoReq = {0x02}; device returns {0x02, fa, ct32}
//   5. decrypt ct → sRand16 + seed2 → sessionKey = MD5(login_key[seed] || sRand)
//   6. encrypted session frames: AES-128-CBC(sessionKey, aesIv)

import Foundation

public struct SessionHandshake {
    public init() {}
    var privKey = Big()          // 20B significant
    public var pubKey = [UInt8]()       // 40B
    public var devPubKey = [UInt8]()    // 40B
    public var shareKey = [UInt8]()     // 20B
    public var aesKey = [UInt8]()       // 16B
    public var aesIv = [UInt8]()        // 16B (md5(share[0:20]))
    public var sessionKey = [UInt8]()   // 16B
    public var sRand = [UInt8]()        // 16B
    public var seed = [UInt8]()         // 2B
    var stage: Stage = .idle

    enum Stage {
        case idle, pubExchSent, keyInfoSent, established
    }

    // CRC16 reflected-0xA001 init 0 (matches chk_crc16)
    static let crc16Tab: [UInt16] = {
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
    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for b in data { c = SessionHandshake.crc16Tab[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    // CRC8 reflected-0x07 init 0 (header check byte of the AA frame — verified
    // against app and device frames: crc8(aa022000)=0x1b, crc8(aa020000)=0xb5)
    // CRC8 — MSB-first, poly 0x07, init 0 (matches the device's crc table:
    // crc8(aa020000)=0xb5, crc8(aa022000)=0x1b, crc8(aa02bc00)=0x06)
    public static func crc8(_ data: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for b in data {
            c ^= b
            for _ in 0..<8 {
                c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : (c << 1)
            }
        }
        return c
    }

    // Build a plaintext V4 frame: 5a5a 00 01 lenLE payload crc16LE
    public static func buildPlaintext(_ payload: [UInt8], version: UInt8 = 0x01) -> Data {
        let len = payload.count + 2
        var f: [UInt8] = [0x5A, 0x5A, 0x00, version,
                          UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)]
        f += payload
        let c = crc16(f)
        f += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF)]
        return Data(f)
    }

    // Build an encrypted session frame (verified against the app's live session):
    //   inner = AA-frame (16-byte header, fully disassembly-verified):
    //     aa 02 <len u16 LE> <hdr-crc8 over [0..3]> <flags 0x0d>
    //     <ctr u32 LE> <seq u16 LE> <src> <dst> <cmd_func> <cmd_id>
    //     <payload len B> <crc16 over the whole frame minus 2B>
    //   ct    = AES-128-CBC(sessionKey, iv, inner + PKCS pad)
    //   outer = 5a5a 10 01 lenLE(ct+2) ct crc16LE
    public static func buildAaFrame(len: UInt8, flags: UInt8, ctr: UInt32, ctr2: UInt32,
                             src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                             payload: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0xAA, 0x02, len, 0x00]           // magic, type, len u16 LE
        f.append(crc8(Array(f[0..<4])))                    // header CRC8 over [0..3]
        f.append(flags)                                    // 0x0d = need_ack + crc16
        f += withUnsafeBytes(of: ctr.littleEndian) { Array($0) }
        f += withUnsafeBytes(of: ctr2.littleEndian) { Array($0.prefix(2)) }  // seq u16
        f += [src, dst, cmdFunc, cmdId]
        f += payload
        let c = crc16(f)
        f += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF)]
        return f
    }

    static func buildEncrypted(_ payload: [UInt8], key: [UInt8], iv: [UInt8]) -> Data {
        buildEncryptedAaFrame(payload, key: key, iv: iv, ctr: 0, ctr2: 0)
    }

    static func buildEncryptedAaFrame(_ payload: [UInt8], key: [UInt8], iv: [UInt8],
                                      ctr: UInt32, ctr2: UInt32) -> Data {
        let inner = Array(buildPlaintext(payload))
        // placeholder for raw aa frame usage — see buildAaEncrypted below
        var padded = inner
        let padLen = 16 - (padded.count % 16)
        padded += [UInt8](repeating: UInt8(padLen), count: padLen)
        let cipher = aesCBCEncrypt(padded, key: key, iv: iv)!
        let ln = cipher.count + 2
        var f: [UInt8] = [0x5A, 0x5A, 0x10, 0x01,
                          UInt8(ln & 0xFF), UInt8((ln >> 8) & 0xFF)]
        f += cipher
        let c = crc16(f)
        f += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF)]
        return Data(f)
    }

    // build an encrypted frame whose inner is an AA-frame
    public static func buildAaEncrypted(src: UInt8, dst: UInt8, cmdFunc: UInt8, cmdId: UInt8,
                                 payload: [UInt8], ctr: UInt32, ctr2: UInt32,
                                 key: [UInt8], iv: [UInt8]) -> Data {
        let inner = buildAaFrame(len: UInt8(payload.count), flags: 0x0d,
                                 ctr: ctr, ctr2: ctr2,
                                 src: src, dst: dst, cmdFunc: cmdFunc, cmdId: cmdId,
                                 payload: payload)
        var padded = inner
        let padLen = 16 - (padded.count % 16)
        padded += [UInt8](repeating: UInt8(padLen), count: padLen)
        let cipher = aesCBCEncrypt(padded, key: key, iv: iv)!
        let ln = cipher.count + 2
        var f: [UInt8] = [0x5A, 0x5A, 0x10, 0x01,
                          UInt8(ln & 0xFF), UInt8((ln >> 8) & 0xFF)]
        f += cipher
        let c = crc16(f)
        f += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF)]
        return Data(f)
    }

    // Decrypt an encrypted frame body: AES-CBC → PKCS-unpad → raw AA-frame bytes
    public static func decryptBody(_ cipher: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard cipher.count % 16 == 0, !cipher.isEmpty else { return nil }
        guard let plainData = aesCBCDecrypt(cipher, key: key, iv: iv) else { return nil }
        var plain = [UInt8](plainData)
        if let last = plain.last, last >= 1, last <= 16, Int(last) < plain.count {
            let start = plain.count - Int(last)
            if plain[start...].allSatisfy({ $0 == last }) {
                plain = Array(plain[0..<start])
            }
        }
        return plain
    }

    // Parse an AA-frame (the inner session frame). Layout verified against the
    // app's own codec; model + deobfuscation live in Frame/AaFrame.swift.
    public static func parseAaFrame(_ data: [UInt8]) -> AaFrame? {
        AaFrame.parse(data)
    }

    // Parse a received V4 frame from a byte buffer. Returns (payload, encrypted, consumed)
    public static func parseV4Frame(_ buf: [UInt8], key: [UInt8], iv: [UInt8]) -> (payload: [UInt8], encrypted: Bool, consumed: Int)? {
        guard buf.count >= 10, buf[0] == 0x5A, buf[1] == 0x5A else {
            // find header if not at 0
            guard let idx = buf.firstIndex(where: { $0 == 0x5A }) else { return nil }
            if idx + 1 < buf.count && buf[idx + 1] == 0x5A {
                return parseV4Frame(Array(buf[idx...]), key: key, iv: iv)
            }
            return nil
        }
        let flags = buf[2]
        guard flags == 0x00 || flags == 0x10, buf[3] == 0x01 else { return nil }
        let lenField = Int(buf[4]) | (Int(buf[5]) << 8)
        let total = lenField + 6
        guard buf.count >= total else { return nil }  // incomplete
        // verify crc
        let storedCrc = UInt16(buf[total - 2]) | (UInt16(buf[total - 1]) << 8)
        guard crc16(Array(buf[0..<(total - 2)])) == storedCrc else {
            return (payload: [], encrypted: false, consumed: total)  // bad crc, skip
        }
        let body = Array(buf[6..<(total - 2)])
        if flags == 0x10 {
            guard let plain = decryptBody(body, key: key, iv: iv) else {
                return (payload: body, encrypted: true, consumed: total)
            }
            return (payload: plain, encrypted: true, consumed: total)
        }
        return (payload: body, encrypted: false, consumed: total)
    }

    // Start the exchange: generate keypair, return the pubKeyExchange frame
    mutating func startExchange() -> Data {
        // random priv: 20 bytes, reduced mod curve order (keypair via Curve160)
        var privBytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &privBytes)
        privKey = Big(privBytes)
        // ensure 1 <= priv < n
        privKey = privKey.mod(Curve160.n)
        if privKey.isZero { privKey = Big(1) }
        pubKey = Curve160.publicKey(priv: privKey)
        stage = .pubExchSent
        print("[hs] appPub:", pubKey.map { String(format: "%02x", $0) }.joined())
        return SessionHandshake.buildPlaintext([0x01, 0x00] + pubKey)
    }

    // Process the device's pubkey response: {0x01, 0x00, 0x00, devPub40}
    mutating func onPubKeyResponse(_ payload: [UInt8]) -> Data? {
        guard payload.count >= 3 + 40, payload[0] == 0x01, payload[1] == 0x00 else {
            print("[hs] pubkey response unexpected:", payload.prefix(8).map { String(format: "%02x", $0) }.joined())
            return nil
        }
        devPubKey = Array(payload[3..<(3 + 40)])
        print("[hs] devPub:", devPubKey.map { String(format: "%02x", $0) }.joined())
        shareKey = Curve160.sharedSecret(priv: privKey, devPub: devPubKey)
        aesKey = Array(shareKey[0..<16])
        let md5share = md5(Data(shareKey))
        aesIv = [UInt8](md5share)
        stage = .keyInfoSent
        print("[hs] share:", shareKey.map { String(format: "%02x", $0) }.joined())
        return SessionHandshake.buildPlaintext([0x02])  // getKeyInfoReq
    }

    // Process the key-info response: {0x02, fa, ct32}
    // decrypt payload[1:] with aesKey/aesIv → sRand16 + seed2
    mutating func onKeyInfoResponse(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 2 else { return false }
        let ct = Array(payload[1...])
        guard ct.count % 16 == 0, ct.count >= 16 else {
            print("[hs] keyInfo ct len:", ct.count)
            return false
        }
        guard let plain = aesCBCDecrypt(ct, key: aesKey, iv: aesIv) else {
            print("[hs] keyInfo decrypt failed")
            return false
        }
        guard plain.count >= 18 else {
            print("[hs] keyInfo plain too short:", plain.count)
            return false
        }
        sRand = Array(plain[0..<16])
        seed = Array(plain[16..<18])
        print("[hs] sRand:", sRand.map { String(format: "%02x", $0) }.joined())
        print("[hs] seed:", seed.map { String(format: "%02x", $0) }.joined())
        // generateSessionKey(seed, sRand) = MD5(login_key[seed[0]*16 + (seed[1]-1)*256] || sRand)[0:16]
        sessionKey = SessionHandshake.sessionKeyFromSeed(seed: seed, sRand: sRand)
        print("[hs] sessionKey:", sessionKey.map { String(format: "%02x", $0) }.joined())
        stage = .established
        return true
    }

    // load login_key table: env var → bytes override → Bundle.main → CWD →
    // legacy dev-machine path (kept for the CLI on this machine)
    public static var loginKeyTablePathOverride: String?
    public static var loginKeyTableBytesOverride: [UInt8]?
    static var loginKeyTable: [UInt8]? = {
        if let b = loginKeyTableBytesOverride { return b }
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["ECOFLOW_LOGIN_KEY_TABLE"] {
            paths.append(env)
        }
        if let o = loginKeyTablePathOverride { paths.append(o) }
        if let res = Bundle.main.url(forResource: "login-key-table", withExtension: "bin") {
            paths.append(res.path)
        }
        paths.append("login-key-table.bin")
        paths.append("/Users/macbookpro/dev/ecoflow-decomp/ble/login-key-table.bin")
        for p in paths {
            if let d = FileManager.default.contents(atPath: p) { return [UInt8](d) }
        }
        print("[hs] WARNING: login-key-table.bin not found")
        return nil
    }()

    public static func sessionKeyFromSeed(seed: [UInt8], sRand: [UInt8]) -> [UInt8] {
        guard let tbl = loginKeyTable, seed.count >= 2 else { return [] }
        // EMPIRICALLY VERIFIED via the app's own session (seed 0502 → offset 336):
        // offset = seed[0]*16 + (seed[1]-1)*256   (simple byte-based table indexing)
        let offset = Int(seed[0]) * 16 + (Int(seed[1]) - 1) * 256
        guard offset >= 0, offset + 16 <= tbl.count else { return [] }
        var md5input = Array(tbl[offset..<(offset + 16)]) + sRand
        let digest = md5(Data(md5input))
        _ = digest
        md5input.removeAll()
        return [UInt8](digest.prefix(16))
    }
}
