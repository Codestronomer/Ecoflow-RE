// Self-test for Secp160.swift
import Foundation

func runSelfTest() {
    let G = Curve160.Point(x: Curve160.gx, y: Curve160.gy)
    let y2 = Big.mul(G.y, G.y).mod(Curve160.p)
    let x3 = Big.mul(G.x, Big.mul(G.x, G.x).mod(Curve160.p)).mod(Curve160.p)
    let rhs = Big.add(Big.add(x3, Big.mul(Curve160.a, G.x).mod(Curve160.p)).mod(Curve160.p), Curve160.b).mod(Curve160.p)
    print("G on curve:", y2.d == rhs.d)

    let k1 = Big([0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34,
                  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    let k2 = Big([0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
                  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    let P1 = Curve160.mul(k1, G)
    let P2 = Curve160.mul(k2, G)
    let s1 = Curve160.mul(k1, P2)
    let s2 = Curve160.mul(k2, P1)
    print("ECDH self-consistency:", s1.x.d == s2.x.d)
    print("shared:", s1.x.toBytes(20).map { String(format: "%02x", $0) }.joined())

    let pub = Curve160.publicKey(priv: k1)
    let dx = Big(Array(pub[0..<20]))
    let dy = Big(Array(pub[20..<40]))
    let y2c = Big.mul(dy, dy).mod(Curve160.p)
    let x3c = Big.mul(dx, Big.mul(dx, dx).mod(Curve160.p)).mod(Curve160.p)
    let rhsc = Big.add(Big.add(x3c, Big.mul(Curve160.a, dx).mod(Curve160.p)).mod(Curve160.p), Curve160.b).mod(Curve160.p)
    print("derived pub on curve:", y2c.d == rhsc.d)
    print("pub len:", pub.count)
}

@main struct SelfTestMain { static func main() { runSelfTest(); runSelfTest2() } }
func runSelfTest2() {
    let aa = Big([0x12,0x34,0x56,0x78])
    let bb = Big([0x9A,0xBC,0xDE,0xFC])
    let prod = Big.mul(aa, bb)
    print("mul check:", prod.toBytes(8).map { String(format: "%02x", $0) }.joined())
    let m = Curve160.p
    let m1 = Big.mul(aa, bb).mod(m)
    print("mod check:", m1.toBytes(20).map { String(format: "%02x", $0) }.joined())
    // python check of the same: print in python
}
