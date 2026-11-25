// Golden-frame tests — the built AA-frames must stay byte-identical to the
// app's own known-good frames (captured from the official app's live session).
// Secrets are never embedded here: CRC self-consistency is checked instead.
import Testing
import Foundation
@testable import EcoFlowKit

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite struct GoldenFrameTests {
    @Test func getAuthStatusMatchesApp() {
        // app frame: aa020000b50d00000000000021353589c584
        let built = SessionHandshake.buildAaFrame(len: 0, flags: 0x0d, ctr: 0, ctr2: 0,
                                                  src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x89,
                                                  payload: [])
        #expect(built.hex == "aa020000b50d00000000000021353589c584")
    }

    @Test func heartbeatMatchesApp() {
        // app frame: aa020000b50d000000000000210220597b46
        let built = SessionHandshake.buildAaFrame(len: 0, flags: 0x0d, ctr: 0, ctr2: 0,
                                                  src: 0x21, dst: 0x02, cmdFunc: 0x20, cmdId: 0x59,
                                                  payload: [])
        #expect(built.hex == "aa020000b50d000000000000210220597b46")
    }

    @Test func acOnFrameMatchesApp() {
        // app frame: aa020700de0d0000000000002105204201ffffffffffff6b11
        let built = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0, ctr2: 0,
                                                  src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                  payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(built[0...15].hex == "aa020700de0d00000000000021052042")
        #expect(built[16...22].hex == "01ffffffffffff")
    }

    @Test func checkAuthStructureAndCrc() {
        // structure: aa 02 20 00 <crc8=1b> <flags=0d> <ctr=0> <seq=0> 21 35 35 86 <32B> <crc16>
        // (CRC self-consistency only — the app's golden CRC used the real secret)
        let built = SessionHandshake.buildAaFrame(len: 32, flags: 0x0d, ctr: 0, ctr2: 0,
                                                  src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x86,
                                                  payload: Array("0123456789ABCDEF0123456789ABCDEF".utf8))
        #expect(built.count == 50)
        #expect(built[0...5].hex == "aa0220001b0d")
        #expect(built[6...11].hex == "000000000000")
        #expect(built[12...15].hex == "21353586")
        let stored = UInt16(built[built.count - 2]) | (UInt16(built[built.count - 1]) << 8)
        #expect(stored == SessionHandshake.crc16(Array(built[0..<(built.count - 2)])))
    }
}

@Suite struct CrcTests {
    @Test func crc8Vectors() {
        #expect(SessionHandshake.crc8([0xAA, 0x02, 0x00, 0x00]) == 0xb5)
        #expect(SessionHandshake.crc8([0xAA, 0x02, 0x20, 0x00]) == 0x1b)
        #expect(SessionHandshake.crc8([0xAA, 0x02, 0xBC, 0x00]) == 0x06)
        #expect(SessionHandshake.crc8([0xAA, 0x02, 0x07, 0x00]) == 0xde)
    }

    @Test func crc16RoundTrip() {
        let frame = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0, ctr2: 0,
                                                  src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                  payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let stored = UInt16(frame[frame.count - 2]) | (UInt16(frame[frame.count - 1]) << 8)
        #expect(stored == SessionHandshake.crc16(Array(frame[0..<(frame.count - 2)])))
    }
}

@Suite struct ObfuscationTests {
    @Test func clearFramesAreNotMasked() {
        // header[6] = 0x04 (ctr low byte) and 0x00 both mean clear
        for ctr in [UInt32(4), UInt32(0)] {
            let built = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: ctr, ctr2: 0,
                                                      src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                      payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            let parsed = SessionHandshake.parseAaFrame(built)!
            #expect(parsed.obfuscated == false)
            #expect(parsed.payload == [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        }
    }

    @Test func maskedFrameRoundTrip() {
        // header[6] = 0xf5 (ctr low byte) → key = 0xf5 ^ 0x04 = 0xf1
        let plain: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        let built = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0xf5, ctr2: 0,
                                                  src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                  payload: plain)
        let parsed = SessionHandshake.parseAaFrame(built)!
        #expect(parsed.obfuscated == true)
        #expect(parsed.payload == plain.map { $0 ^ 0xf1 })
        // header[6] = 0xb8 → key 0xbc
        let built2 = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0xb8, ctr2: 0,
                                                   src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                   payload: plain)
        let parsed2 = SessionHandshake.parseAaFrame(built2)!
        #expect(parsed2.obfuscated == true)
        #expect(parsed2.payload == plain.map { $0 ^ 0xbc })
    }
}
