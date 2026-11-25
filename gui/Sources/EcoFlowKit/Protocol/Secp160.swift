// Minimal secp160r1 (160-bit) EC math for the EcoFlow session handshake.
// Uses [UInt32] little-endian limb arithmetic; values big-endian at the byte interface
// (matches uECC byte format: pub = X(20) || Y(20), shared = X(priv*pub) 20B).

import Foundation

public struct Big {
    var d: [UInt32]   // little-endian base 2^32, fixed 14 limbs (448-bit headroom) — products need 10

    init() { d = [UInt32](repeating: 0, count: 14) }
    init(_ v: UInt32) { d = [UInt32](repeating: 0, count: 14); d[0] = v }
    public init(_ bytes: [UInt8]) {  // big-endian bytes
        d = [UInt32](repeating: 0, count: 14)
        var byteIndex = bytes.count
        var limb = 0
        while byteIndex > 0 && limb < 14 {
            var v: UInt32 = 0
            let take = min(4, byteIndex)
            for k in 0..<take {
                v = (v << 8) | UInt32(bytes[byteIndex - take + k])
            }
            d[limb] = v
            byteIndex -= take
            limb += 1
        }
    }

    var isZero: Bool { d.allSatisfy { $0 == 0 } }

    func toBytes(_ n: Int) -> [UInt8] {  // big-endian, n bytes
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let limb = i / 4
            let shift = UInt32(i % 4) * 8
            let v = limb < 14 ? d[limb] : 0
            out[n - 1 - i] = UInt8((v >> shift) & 0xFF)
        }
        return out
    }

    static func add(_ a: Big, _ b: Big) -> Big {
        var r = Big()
        var carry: UInt64 = 0
        for i in 0..<14 {
            let s = UInt64(a.d[i]) + UInt64(b.d[i]) + carry
            r.d[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        return r
    }

    static func sub(_ a: Big, _ b: Big) -> Big {
        var r = Big()
        var borrow: Int64 = 0
        for i in 0..<14 {
            var diff = Int64(a.d[i]) - Int64(b.d[i]) - borrow
            if diff < 0 { diff += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            r.d[i] = UInt32(truncatingIfNeeded: diff)
        }
        return r
    }

    // modular subtraction: (a - b) mod p — adds p back on borrow instead of 2^448
    static func subMod(_ a: Big, _ b: Big, _ m: Big) -> Big {
        var r = Big()
        var borrow: Int64 = 0
        for i in 0..<14 {
            var diff = Int64(a.d[i]) - Int64(b.d[i]) - borrow
            if diff < 0 { diff += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            r.d[i] = UInt32(truncatingIfNeeded: diff)
        }
        if borrow == 1 {
            r = Big.add(r, m)  // (a-b) + m; a,b < m so result < 2m < 2^161, fits
        }
        return r
    }

    static func cmp(_ a: Big, _ b: Big) -> Int {
        for i in stride(from: 13, through: 0, by: -1) {
            if a.d[i] != b.d[i] { return a.d[i] < b.d[i] ? -1 : 1 }
        }
        return 0
    }

    static func mul(_ a: Big, _ b: Big) -> Big {
        var r = [UInt32](repeating: 0, count: 14)
        for i in 0..<7 {
            if a.d[i] == 0 { continue }
            var carry: UInt64 = 0
            for j in 0..<7 {
                if i + j >= 14 { break }
                let cur = UInt64(r[i + j]) + UInt64(a.d[i]) * UInt64(b.d[j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: cur)
                carry = cur >> 32
            }
            if i + 7 < 14 { r[i + 7] = UInt32(truncatingIfNeeded: carry) }
        }
        var out = Big()
        for i in 0..<14 { out.d[i] = r[i] }
        return out
    }

    func shl1() -> Big {
        var r = self
        var carry: UInt32 = 0
        for i in 0..<14 {
            let nc = r.d[i] >> 31
            r.d[i] = (r.d[i] << 1) | carry
            carry = nc
        }
        return r
    }

    // mod m via binary long division (m < 2^160, self up to 2^448)
    func mod(_ m: Big) -> Big {
        let bits = bitLength()
        if bits <= 160 && Big.cmp(self, m) < 0 { return self }
        var rem = Big()
        for i in stride(from: bits - 1, through: 0, by: -1) {
            rem = rem.shl1()
            if bit(i) { rem.d[0] |= 1 }
            if Big.cmp(rem, m) >= 0 {
                rem = Big.sub(rem, m)
            }
        }
        return rem
    }

    func bit(_ i: Int) -> Bool {
        if i >= 448 { return false }
        return (d[i / 32] >> UInt32(i % 32)) & 1 == 1
    }

    func bitLength() -> Int {
        for i in stride(from: 13, through: 0, by: -1) {
            if d[i] != 0 { return i * 32 + (32 - d[i].leadingZeroBitCount) }
        }
        return 0
    }

    static func powMod(_ base: Big, _ e: Big, _ m: Big) -> Big {
        var result = Big(1)
        var b = base.mod(m)
        for i in stride(from: e.bitLength() - 1, through: 0, by: -1) {
            result = Big.mul(result, result).mod(m)
            if e.bit(i) { result = Big.mul(result, b).mod(m) }
        }
        return result
    }

    func invMod(_ m: Big) -> Big {  // Fermat (m prime)
        var e = m
        e.d[0] -= 2  // m - 2
        return Big.powMod(self, e, m)
    }
}

// secp160r1
public struct Curve160 {
    static let p = Big([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF])
    static let a = Big([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFC])
    static let b = Big([0x1C, 0x97, 0xBE, 0xFC, 0x54, 0xBD, 0x7A, 0x8B, 0x65, 0xAC,
                        0xF8, 0x9F, 0x81, 0xD4, 0xD4, 0xAD, 0xC5, 0x65, 0xFA, 0x45])
    static let gx = Big([0x4A, 0x96, 0xB5, 0x68, 0x8E, 0xF5, 0x73, 0x28, 0x46, 0x64,
                         0x69, 0x89, 0x68, 0xC3, 0x8B, 0xB9, 0x13, 0xCB, 0xFC, 0x82])
    static let gy = Big([0x23, 0xA6, 0x28, 0x55, 0x31, 0x68, 0x94, 0x7D, 0x59, 0xDC,
                         0xC9, 0x12, 0x04, 0x23, 0x51, 0x37, 0x7A, 0xC5, 0xFB, 0x32])
    static let n = Big([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x01, 0xF4, 0xC8, 0xF9, 0x27, 0xAE, 0xD3, 0xCA, 0x75, 0x22, 0x57])
    // note: n is 161-bit value; Big has 7 limbs so fine

    struct Point { var x: Big; var y: Big; var inf: Bool = false
        static let infinity = Point(x: Big(), y: Big(), inf: true) }

    static func add(_ P: Point, _ Q: Point) -> Point {
        if P.inf { return Q }
        if Q.inf { return P }
        if P.x.d == Q.x.d {
            let ysum = Big.add(P.y, Q.y)
            if ysum.isZero || (P.y.d == Q.y.d && false) {
                // doubling handled below; if y==0 -> infinity
                if ysum.isZero { return .infinity }
            }
        }
        if P.x.d == Q.x.d && P.y.d == Q.y.d {
            // doubling: l = (3x^2 + a) / 2y; x3 = l^2 - 2x; y3 = l*(x - x3) - y
            let x2 = Big.mul(P.x, P.x).mod(p)
            let num = Big.add(Big.mul(Big(3), x2).mod(p), a).mod(p)
            let den = Big.mul(Big(2), P.y).mod(p).invMod(p)
            let l = Big.mul(num, den).mod(p)
            let x2x = Big.add(P.x, P.x).mod(p)
            let x3 = Big.subMod(Big.mul(l, l).mod(p), x2x, p)
            let sx = Big.subMod(P.x, x3, p)
            let y3 = Big.mul(l, sx).mod(p)
            let yy = Big.subMod(y3, P.y, p)
            return Point(x: x3, y: yy)
        }
        // general addition
        let dy = Big.subMod(Q.y, P.y, p)
        let dx = Big.subMod(Q.x, P.x, p)
        if dx.isZero { return .infinity }
        let l = Big.mul(dy, dx.invMod(p)).mod(p)
        let x3 = Big.subMod(Big.subMod(Big.mul(l, l).mod(p), P.x, p), Q.x, p)
        let sx = Big.subMod(P.x, x3, p)
        let y3 = Big.mul(l, sx).mod(p)
        let yy = Big.subMod(y3, P.y, p)
        return Point(x: x3, y: yy)
    }

    static func mul(_ k: Big, _ P: Point) -> Point {
        var result = Point.infinity
        var a = P
        let bits = k.bitLength()
        for i in stride(from: 0, through: bits - 1, by: 1) {
            if k.bit(i) { result = add(result, a) }
            a = add(a, a)
        }
        return result
    }

    // public key: 40 bytes X || Y
    public static func publicKey(priv: Big) -> [UInt8] {
        let P = mul(priv, Point(x: gx, y: gy))
        return P.x.toBytes(20) + P.y.toBytes(20)
    }

    // shared secret: X(priv * devPub), 20 bytes
    public static func sharedSecret(priv: Big, devPub: [UInt8]) -> [UInt8] {
        let dx = Big(Array(devPub[0..<20]))
        let dy = Big(Array(devPub[20..<40]))
        let P = mul(priv, Point(x: dx, y: dy))
        return P.x.toBytes(20)
    }
}
