// frame-selftest.swift — verify the AA-frame builder against the app's known
// good frame (captured from the official app's own live session).
import Foundation

let expected = "aa020000b50d00000000000021353589c584"
let built = SessionHandshake.buildAaFrame(len: 0, flags: 0x0d, ctr: 0, ctr2: 0,
                                          src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x89,
                                          payload: [])
let builtHex = built.map { String(format: "%02x", $0) }.joined()

print("expected: \(expected)")
print("built:    \(builtHex)")
print("MATCH: \(builtHex == expected)")
print("crc8(aa020000) = \(String(format: "%02x", SessionHandshake.crc8([0xAA, 0x02, 0x00, 0x00])))  (expect b5)")
print("crc8(aa022000) = \(String(format: "%02x", SessionHandshake.crc8([0xAA, 0x02, 0x20, 0x00])))  (expect 1b)")
print("crc8(aa02bc00) = \(String(format: "%02x", SessionHandshake.crc8([0xAA, 0x02, 0xBC, 0x00])))  (expect 06)")

// also check the checkAuth frame with the verified secret
let secret = Array("<AUTH_SECRET>".utf8)
let checkAuth = SessionHandshake.buildAaFrame(len: 32, flags: 0x0d, ctr: 0, ctr2: 0,
                                              src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x86,
                                              payload: secret)
let caHex = checkAuth.map { String(format: "%02x", $0) }.joined()
let expectedCA = "aa0220001b0d00000000000021353586<SECRET_HEX>924b"
print("checkAuth MATCH: \(caHex == expectedCA)")
