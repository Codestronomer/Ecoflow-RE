import Foundation
import CommonCrypto

func md5(_ data: Data) -> Data {
    var d = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { ptr in CC_MD5(ptr.baseAddress, CC_LONG(data.count), &d) }
    return Data(d)
}
func aesCBCEncrypt(_ input: Data, key: Data, iv: Data) -> Data? {
    guard key.count == kCCKeySizeAES128 else { print("key size fail \(key.count)"); return nil }
    var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var outLen = 0
    let status = input.withUnsafeBytes { inPtr in
        key.withUnsafeBytes { kPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                        kPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                        inPtr.baseAddress, input.count, &out, out.count, &outLen)
            }
        }
    }
    print("cccrypt status: \(status), outLen: \(outLen), inLen: \(input.count)")
    return status == kCCSuccess ? Data(out.prefix(outLen)) : nil
}
let sn = "<SN>"
let key = md5(Data(sn.utf8)), iv = md5(Data(String(sn.reversed()).utf8))
print("key ok \(key.count), iv ok \(iv.count)")
var input = [UInt8](repeating: 0x41, count: 19)
input.append(0x11); input.append(0x22)
while input.count % 16 != 0 { input.append(0) }
if let c = aesCBCEncrypt(Data(input), key: key, iv: iv) {
    print("cipher: \(c.map { String(format: "%02x", $0) }.joined())")
} else { print("ENCRYPT FAILED") }
