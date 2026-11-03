import CommonCrypto
import Foundation

/// AES-CTR and AES-CBC via CommonCrypto, for OpenSSH key files
/// (`aes128-ctr`, `aes192-ctr`, `aes256-ctr`, `aes128-cbc`, `aes256-cbc`).
enum AESCipher {
    enum Mode { case ctr, cbc }

    static func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8], mode: Mode) throws -> [UInt8] {
        try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv, mode: mode)
    }

    static func encrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], mode: Mode) throws -> [UInt8] {
        try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv, mode: mode)
    }

    private static func crypt(_ operation: CCOperation, _ input: [UInt8], key: [UInt8], iv: [UInt8], mode: Mode) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else {
            throw SSHKeyError.invalidFormat("invalid AES key or IV length")
        }
        guard mode == .ctr || input.count % 16 == 0 else {
            throw SSHKeyError.invalidFormat("ciphertext is not a multiple of the block size")
        }
        var cryptor: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            operation,
            mode == .ctr ? CCMode(kCCModeCTR) : CCMode(kCCModeCBC),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            iv, key, key.count,
            nil, 0, 0,
            mode == .ctr ? CCModeOptions(kCCModeOptionCTR_BE) : 0,
            &cryptor)
        guard status == kCCSuccess, let cryptor else {
            throw SSHKeyError.invalidFormat("could not initialise AES (\(status))")
        }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        var total = 0
        let updateStatus = input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                CCCryptorUpdate(cryptor, inputPointer.baseAddress, input.count, outputPointer.baseAddress, outputPointer.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess else {
            throw SSHKeyError.invalidFormat("AES failed (\(updateStatus))")
        }
        total += moved
        let finalStatus = output.withUnsafeMutableBufferPointer { outputPointer in
            CCCryptorFinal(cryptor, outputPointer.baseAddress! + total, outputPointer.count - total, &moved)
        }
        guard finalStatus == kCCSuccess else {
            throw SSHKeyError.invalidFormat("AES failed (\(finalStatus))")
        }
        total += moved
        return Array(output[0..<total])
    }
}
