import Foundation

/// Argon2 (RFC 9106) in pure Swift: Argon2d, Argon2i and Argon2id, version 0x13.
/// Used for `.tepfa` export encryption and PuTTY v3 key files. Slow in debug
/// builds; tests use small parameters.
public enum Argon2 {
    public enum Variant: Int, Sendable {
        case d = 0
        case i = 1
        case id = 2
    }

    public struct Parameters: Sendable, Equatable {
        public var variant: Variant
        public var memoryKiB: UInt32
        public var iterations: UInt32
        public var parallelism: UInt32

        public init(variant: Variant = .id, memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32 = 1) {
            self.variant = variant
            self.memoryKiB = memoryKiB
            self.iterations = iterations
            self.parallelism = parallelism
        }

        /// 64 MiB, 3 passes, 1 lane: the RFC's recommended "second option".
        public static let exportDefault = Parameters(variant: .id, memoryKiB: 65_536, iterations: 3, parallelism: 1)
    }

    public enum Error: Swift.Error, Equatable {
        case invalidParameters(String)
    }

    private static let blockWords = 128
    private static let version: UInt32 = 0x13

    /// Derives `outputLength` bytes.
    public static func hash(
        password: [UInt8],
        salt: [UInt8],
        secret: [UInt8] = [],
        associatedData: [UInt8] = [],
        parameters: Parameters,
        outputLength: Int
    ) throws -> [UInt8] {
        let p = Int(parameters.parallelism)
        let t = Int(parameters.iterations)
        guard p >= 1, p <= 0xFFFFFF else { throw Error.invalidParameters("parallelism must be 1...16777215") }
        guard t >= 1 else { throw Error.invalidParameters("iterations must be at least 1") }
        guard Int(parameters.memoryKiB) >= 8 * p else { throw Error.invalidParameters("memory must be at least 8 KiB per lane") }
        guard outputLength >= 4 else { throw Error.invalidParameters("output must be at least 4 bytes") }
        guard salt.count >= 8 else { throw Error.invalidParameters("salt must be at least 8 bytes") }

        // H0
        var h0Input: [UInt8] = []
        h0Input.append(le32(UInt32(p)))
        h0Input.append(le32(UInt32(outputLength)))
        h0Input.append(le32(parameters.memoryKiB))
        h0Input.append(le32(UInt32(t)))
        h0Input.append(le32(version))
        h0Input.append(le32(UInt32(parameters.variant.rawValue)))
        h0Input.append(le32(UInt32(password.count)))
        h0Input.append(contentsOf: password)
        h0Input.append(le32(UInt32(salt.count)))
        h0Input.append(contentsOf: salt)
        h0Input.append(le32(UInt32(secret.count)))
        h0Input.append(contentsOf: secret)
        h0Input.append(le32(UInt32(associatedData.count)))
        h0Input.append(contentsOf: associatedData)
        let h0 = BLAKE2b.hash(h0Input, outputLength: 64)

        // Memory layout: p lanes × q columns, each block 128 words.
        let blocks = 4 * p * (Int(parameters.memoryKiB) / (4 * p))
        let q = blocks / p
        let segmentLength = q / 4
        var memory = [UInt64](repeating: 0, count: blocks * blockWords)

        func blockIndex(lane: Int, column: Int) -> Int { (lane * q + column) * blockWords }

        for lane in 0..<p {
            for column in 0..<2 {
                let input = h0 + le32(UInt32(column)) + le32(UInt32(lane))
                let bytes = variableHash(input, outputLength: 1024)
                let base = blockIndex(lane: lane, column: column)
                for w in 0..<blockWords {
                    memory[base + w] = loadLE64(bytes, w * 8)
                }
            }
        }

        var addressBlock = [UInt64](repeating: 0, count: blockWords)
        var inputBlock = [UInt64](repeating: 0, count: blockWords)
        var zeroBlock = [UInt64](repeating: 0, count: blockWords)
        var tmp = [UInt64](repeating: 0, count: blockWords)
        var result = [UInt64](repeating: 0, count: blockWords)

        for pass in 0..<t {
            for slice in 0..<4 {
                for lane in 0..<p {
                    let dataIndependent: Bool
                    switch parameters.variant {
                    case .d: dataIndependent = false
                    case .i: dataIndependent = true
                    case .id: dataIndependent = pass == 0 && slice < 2
                    }
                    if dataIndependent {
                        inputBlock = [UInt64](repeating: 0, count: blockWords)
                        inputBlock[0] = UInt64(pass)
                        inputBlock[1] = UInt64(lane)
                        inputBlock[2] = UInt64(slice)
                        inputBlock[3] = UInt64(blocks)
                        inputBlock[4] = UInt64(t)
                        inputBlock[5] = UInt64(parameters.variant.rawValue)
                        inputBlock[6] = 0
                    }
                    let startIndex = (pass == 0 && slice == 0) ? 2 : 0
                    for index in startIndex..<segmentLength {
                        let column = slice * segmentLength + index
                        let previousColumn = column == 0 ? q - 1 : column - 1
                        let previous = blockIndex(lane: lane, column: previousColumn)

                        let j1: UInt64
                        let j2: UInt64
                        if dataIndependent {
                            if index % blockWords == 0 {
                                inputBlock[6] &+= 1
                                compress(&zeroBlock, &inputBlock, into: &tmp, xorInto: false, scratch: &result)
                                compress(&zeroBlock, &tmp, into: &addressBlock, xorInto: false, scratch: &result)
                            }
                            let word = addressBlock[index % blockWords]
                            j1 = word & 0xFFFF_FFFF
                            j2 = word >> 32
                        } else {
                            let word = memory[previous]
                            j1 = word & 0xFFFF_FFFF
                            j2 = word >> 32
                        }

                        // Reference lane and block (RFC 9106 §3.4.1).
                        var referenceLane = Int(j2 % UInt64(p))
                        if pass == 0 && slice == 0 { referenceLane = lane }
                        let sameLane = referenceLane == lane
                        var referenceAreaSize: Int
                        if pass == 0 {
                            if slice == 0 {
                                referenceAreaSize = index - 1
                            } else if sameLane {
                                referenceAreaSize = slice * segmentLength + index - 1
                            } else {
                                referenceAreaSize = slice * segmentLength + (index == 0 ? -1 : 0)
                            }
                        } else if sameLane {
                            referenceAreaSize = q - segmentLength + index - 1
                        } else {
                            referenceAreaSize = q - segmentLength + (index == 0 ? -1 : 0)
                        }
                        let x = (j1 &* j1) >> 32
                        let y = (UInt64(referenceAreaSize) &* x) >> 32
                        let zz = UInt64(referenceAreaSize) - 1 - y
                        var startPosition = 0
                        if pass != 0 {
                            startPosition = slice == 3 ? 0 : (slice + 1) * segmentLength
                        }
                        let referenceColumn = (startPosition + Int(zz)) % q
                        let reference = blockIndex(lane: referenceLane, column: referenceColumn)
                        let current = blockIndex(lane: lane, column: column)

                        var prevBlock = Array(memory[previous..<(previous + blockWords)])
                        var refBlock = Array(memory[reference..<(reference + blockWords)])
                        var out = Array(memory[current..<(current + blockWords)])
                        compress(&prevBlock, &refBlock, into: &out, xorInto: pass != 0, scratch: &result)
                        memory.replaceSubrange(current..<(current + blockWords), with: out)
                    }
                }
            }
        }

        // Final block: XOR of the last column of every lane.
        var final = [UInt64](repeating: 0, count: blockWords)
        for lane in 0..<p {
            let base = blockIndex(lane: lane, column: q - 1)
            for w in 0..<blockWords { final[w] ^= memory[base + w] }
        }
        var finalBytes: [UInt8] = []
        finalBytes.reserveCapacity(1024)
        for word in final {
            for shift in stride(from: 0, to: 64, by: 8) {
                finalBytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return variableHash(finalBytes, outputLength: outputLength)
    }

    // MARK: - Internals

    /// H' from RFC 9106 §3.3.
    static func variableHash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        let prefixed = le32(UInt32(outputLength)) + input
        if outputLength <= 64 {
            return BLAKE2b.hash(prefixed, outputLength: outputLength)
        }
        let r = Int((Double(outputLength) / 32).rounded(.up)) - 2
        var out: [UInt8] = []
        var v = BLAKE2b.hash(prefixed, outputLength: 64)
        out.append(contentsOf: v.prefix(32))
        for _ in 1..<r {
            v = BLAKE2b.hash(v, outputLength: 64)
            out.append(contentsOf: v.prefix(32))
        }
        let remaining = outputLength - 32 * r
        out.append(contentsOf: BLAKE2b.hash(v, outputLength: remaining))
        return out
    }

    /// G(X, Y): `out = (X ⊕ Y) ⊕ P(X ⊕ Y)`, XORed into `out` when `xorInto`.
    private static func compress(_ x: inout [UInt64], _ y: inout [UInt64], into out: inout [UInt64], xorInto: Bool, scratch r: inout [UInt64]) {
        for i in 0..<blockWords { r[i] = x[i] ^ y[i] }
        var z = r
        // Rows: 8 rows of 16 words.
        for row in 0..<8 {
            let b = row * 16
            permute(&z, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        // Columns: 8 columns of 16 words (2 words from each row).
        for column in 0..<8 {
            let b = column * 2
            permute(&z, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49, b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
        }
        if xorInto {
            for i in 0..<blockWords { out[i] ^= z[i] ^ r[i] }
        } else {
            for i in 0..<blockWords { out[i] = z[i] ^ r[i] }
        }
    }

    /// The permutation P over 16 words (RFC 9106 §3.6).
    @inline(__always)
    private static func permute(_ v: inout [UInt64], _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
                                _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(&v, i0, i4, i8, i12)
        gb(&v, i1, i5, i9, i13)
        gb(&v, i2, i6, i10, i14)
        gb(&v, i3, i7, i11, i15)
        gb(&v, i0, i5, i10, i15)
        gb(&v, i1, i6, i11, i12)
        gb(&v, i2, i7, i8, i13)
        gb(&v, i3, i4, i9, i14)
    }

    @inline(__always)
    private static func gb(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = v[a] &+ v[b] &+ 2 &* (v[a] & 0xFFFF_FFFF) &* (v[b] & 0xFFFF_FFFF)
        v[d] = (v[d] ^ v[a]).rotated(right: 32)
        v[c] = v[c] &+ v[d] &+ 2 &* (v[c] & 0xFFFF_FFFF) &* (v[d] & 0xFFFF_FFFF)
        v[b] = (v[b] ^ v[c]).rotated(right: 24)
        v[a] = v[a] &+ v[b] &+ 2 &* (v[a] & 0xFFFF_FFFF) &* (v[b] & 0xFFFF_FFFF)
        v[d] = (v[d] ^ v[a]).rotated(right: 16)
        v[c] = v[c] &+ v[d] &+ 2 &* (v[c] & 0xFFFF_FFFF) &* (v[d] & 0xFFFF_FFFF)
        v[b] = (v[b] ^ v[c]).rotated(right: 63)
    }

    @inline(__always)
    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }

    @inline(__always)
    private static func loadLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var word: UInt64 = 0
        for j in 0..<8 { word |= UInt64(bytes[offset + j]) << UInt64(8 * j) }
        return word
    }
}

private extension Array where Element == UInt8 {
    mutating func append(_ other: [UInt8]) {
        append(contentsOf: other)
    }
}
