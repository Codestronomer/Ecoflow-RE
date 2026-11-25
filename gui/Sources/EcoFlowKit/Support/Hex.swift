// Hex helpers shared by the kit and the CLI.
import Foundation

/// Parse an even-length hex string into bytes. Returns nil on invalid input.
public func hexBytes(_ s: String) -> [UInt8]? {
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

extension Sequence where Element == UInt8 {
    /// Lowercase hex string (logging + tests).
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
