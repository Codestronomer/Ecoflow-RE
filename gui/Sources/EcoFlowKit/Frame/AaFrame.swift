// AA-frame model — the inner session frame.
// Layout (16-byte header, verified against the app's own codec):
//   aa 02 <len u16 LE> <hdr-crc8> <flags> <ctr u32 LE> <seq u16 LE>
//   <src> <dst> <cmd_func> <cmd_id> <payload> <crc16>
import Foundation

public struct AaFrame: Equatable {
    public let len: UInt16
    public let flags: UInt8
    public let ctr: UInt32
    public let seq: UInt16
    public let src: UInt8
    public let dst: UInt8
    public let cmdFunc: UInt8
    public let cmdId: UInt8
    public let payload: [UInt8]
    public let obfuscated: Bool
    public let crcOk: Bool
    public let hdrCrcOk: Bool

    /// Frame CRC + header CRC both valid?
    public var isValid: Bool { crcOk && hdrCrcOk }

    /// Parse a decrypted AA-frame. Payload is de-obfuscated when needed
    /// (header[6] ∉ {0x00, 0x04} → XOR with [6] ^ 0x04).
    public static func parse(_ data: [UInt8]) -> AaFrame? {
        guard data.count >= 18, data[0] == 0xAA, (data[1] & 0x0F) == 0x02 else { return nil }
        let len = UInt16(data[2]) | (UInt16(data[3]) << 8)
        guard data.count >= 16 + Int(len) + 2 else { return nil }
        let hdrCrcOk = SessionHandshake.crc8(Array(data[0..<4])) == data[4]
        let flags = data[5]
        let ctr = UInt32(data[6]) | (UInt32(data[7]) << 8) | (UInt32(data[8]) << 16) | (UInt32(data[9]) << 24)
        let seq = UInt16(data[10]) | (UInt16(data[11]) << 8)
        let src = data[12], dst = data[13], cf = data[14], ci = data[15]
        let stored = UInt16(data[data.count - 2]) | (UInt16(data[data.count - 1]) << 8)
        let crcOk = SessionHandshake.crc16(Array(data[0..<(data.count - 2)])) == stored
        let obfuscated = data[6] != 0x00 && data[6] != 0x04
        var payload = Array(data[16..<(16 + Int(len))])
        if obfuscated {
            let key = data[6] ^ 0x04
            payload = payload.map { $0 ^ key }
        }
        return AaFrame(len: len, flags: flags, ctr: ctr, seq: seq, src: src, dst: dst,
                       cmdFunc: cf, cmdId: ci, payload: payload,
                       obfuscated: obfuscated, crcOk: crcOk, hdrCrcOk: hdrCrcOk)
    }
}
