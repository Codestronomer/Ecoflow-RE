// Crypto helpers shared across the EcoFlow BLE client (MD5, AES-CBC)
import Foundation
import CommonCrypto

public func md5(_ data: Data) -> Data {
    var d = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { ptr in
        CC_MD5(ptr.baseAddress, CC_LONG(data.count), &d)
    }
    return Data(d)
}

public func aesCBCEncrypt(_ input: Data, key: Data, iv: Data) -> Data? {
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

public func aesCBCDecrypt(_ input: Data, key: Data, iv: Data) -> Data? {
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

// [UInt8] convenience overloads
public func aesCBCEncrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> Data? {
    aesCBCEncrypt(Data(input), key: Data(key), iv: Data(iv))
}
public func aesCBCDecrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> Data? {
    aesCBCDecrypt(Data(input), key: Data(key), iv: Data(iv))
}
