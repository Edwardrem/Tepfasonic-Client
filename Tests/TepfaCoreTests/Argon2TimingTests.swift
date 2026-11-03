import Foundation
import Testing
@testable import TepfaCore

/// Opt-in: `TEPFA_ARGON2_TIMING=1 swift test -c release --filter Argon2Timing` prints the cost of the export defaults.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_ARGON2_TIMING"] != nil))
struct Argon2TimingTests {
    @Test func exportDefaultCost() throws {
        let start = ContinuousClock.now
        _ = try Argon2.hash(password: Array("passphrase".utf8), salt: [UInt8](repeating: 7, count: 16), parameters: .exportDefault, outputLength: 32)
        let elapsed = ContinuousClock.now - start
        print("ARGON2_TIMING exportDefault (64 MiB, t=3, p=1): \(elapsed)")
        #expect(elapsed < .seconds(30))
    }
}
