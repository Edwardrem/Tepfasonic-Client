import Foundation
import Testing
@testable import TepfaSSH

@Suite("Key pairs: generation, PEM, PPK, OpenSSH encoding")
struct KeyPairTests {
    // MARK: PuTTY vectors (puttygen 0.85)

    static let ppkEd25519V2 = """
    PuTTY-User-Key-File-2: ssh-ed25519
    Encryption: none
    Comment: ppk-ed25519
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAINxOdG4jxE6Wt9yFg11Fb5Sz8ti9qeoy2pUuwRgQ
    8Vfd
    Private-Lines: 1
    AAAAIHCuZhZwOPYxgBwgKo3HjomsaTCK17RxMMYSsxxO7Qia
    Private-MAC: 10ef113c5d924721908fe93da1ad068e87ad53d0

    """

    static let ppkEd25519V2Encrypted = """
    PuTTY-User-Key-File-2: ssh-ed25519
    Encryption: aes256-cbc
    Comment: ppk-ed25519
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAINxOdG4jxE6Wt9yFg11Fb5Sz8ti9qeoy2pUuwRgQ
    8Vfd
    Private-Lines: 1
    B4HcXaubQlw+jX+2B0R9ZU3SSoz/QEv5Ex3C/9z7sfPr9nBh9AZKuFCzYQFUBDhI
    Private-MAC: 5a4a5e2ceaf32b508a56bc6a7984ed8e779af854

    """

    static let ppkRSAV2 = """
    PuTTY-User-Key-File-2: ssh-rsa
    Encryption: none
    Comment: ppk-rsa
    Public-Lines: 6
    AAAAB3NzaC1yc2EAAAADAQABAAABAQDODk+IZN9/+X5+1wZme1I1wWOP/DeShATw
    Rvw6YTjCSF8/Y/bpI0xQMyoBSA719t9x29Xu5Ah2xNHrr3iSIP8meo1+dCKIvCe8
    Xp0nFlmxXGmu67H4TJCZxMmSD2FxzQ+C96+RIi9er3StrCIJMhhsGmZKvtD/Xs6A
    O7gpg5BFuXRAYVlh9GP57WyLrEovVnN2S0TFmQFfSQWQ6omnTW72pN7hv2PoBPxC
    sGBF2a2VIcyhLYyKHyk/l6Gu1mqNCt8FuGEOzQY0QLMKOqSzpTcxJpRK7TLhLNbH
    TM1uWKc4lnpm3025IrTAZ0rxIcDxpcl1WiBzTAN/1m/PZygMStBx
    Private-Lines: 14
    AAABAQC3ja/zhEhEK/Au9UTSTdCx6g/S1455ifkMQW+2YZy6FNYkFdyBWdxFJQ6q
    DZKmMMBjIL22DJQtmK6XELyLD7G6iTk6CCIrQ9Dx0CaWBybnA7dxBqyGz02QbOhS
    oDjhsxW6SQGwe49O/WUmwEuhfWqcAfhVZR2wHrg9KvWmpXgDYtNx04Awi35cq/Ni
    Aubywme+XK8JtEj4uc6HVCdwJK5ewko8iuSLZ7VJkafQIyaCyKG76Xa1ZSDPkbL0
    mFBywT4XQfKEbU4MuSP3skQpHYqQlX9R4v0zqkpvN6VVI99LoI9x1ooRljTKhxho
    ycVpXSbO/CgN3YJBTyDnDTTuYgNxAAAAgQDtGroPRQH1xRUuwOJFK8g8MnpeHAfb
    doR6kVypcFBEBrF56dWBvD5J2Hl5nbncsABTLKxL6I1wDYuLgcX6eyYexC/eo/gs
    yQrmNeV3cM5e/OlCbNMGnblGqiCPTLl+Jm+diw6ZggnHnUk2ZyndxgHDEdEZ+ZtE
    RxtQIGL4wUOWgwAAAIEA3nomRahburvcAyV/T7pjonwwQuDo0fCLHpO0eEUbureb
    y0Surivu03SD5Ys49QT81KB/1ncI6tTTyfQdPNJEhF8SI9jusVkTu+HCPiM06hF5
    dzskpf+tmC0FJJ/WCr75/7Nb1WsaXynECIG/+hlws5AphdgD2iatC/n048Q8avsA
    AACAB/Ro5gD68hFYXalQnoY8ifagwU5VI7Q6CH4EJqFdT5+j35eVmFrnMWzHS7hP
    YgZl05WWznJX3UnXEzMcwKiBpobzM9JRLl74iCTcB7YxLr6ca9w1OjaLAftMGgeA
    bssMK+kt0VIGyPE8HhQCvs7SbrmXZtm3Rq3o4ocNS8Qrsc8=
    Private-MAC: 9af6bd0b08540491d35f37ffba694eea42834253

    """

    static let ppkP256V3 = """
    PuTTY-User-Key-File-3: ecdsa-sha2-nistp256
    Encryption: none
    Comment: ppk-p256
    Public-Lines: 3
    AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBez1Mo70WnA
    BCH46HVFEQs/izR/27+c84Zo6OHDyw8MzngahzcXHJGhbdEelZ2aPeOxtvv2P8Uw
    HeDzcm3rkX4=
    Private-Lines: 1
    AAAAIQD1TcHjZ8OrFbQ7OJuBj/0cJBbK9Vm74gpMq/4jyjfBpA==
    Private-MAC: b9215464b879466774f35d12ddc7e7ac486049733b54ad70b5e4b35444a8fece

    """

    /// puttygen --ppk-param version=3,kdf=argon2id,memory=8,passes=2,parallelism=1, passphrase "secret"
    static let ppkEd25519V3Argon2id = """
    PuTTY-User-Key-File-3: ssh-ed25519
    Encryption: aes256-cbc
    Comment: v3 argon2 test
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIISTaLg+NdsNL6DCAxzqqbquPQnslJwcy9myQKG0
    hXam
    Key-Derivation: Argon2id
    Argon2-Memory: 8
    Argon2-Passes: 2
    Argon2-Parallelism: 1
    Argon2-Salt: a8a9a6a6903294d10941e3eb05f777f6
    Private-Lines: 1
    vtwJHeYWy4sepr33n+0161Qxw9rG1EkKwqjaDUh7XJ96Aaw3PVA0XmtmSkycYUD1
    Private-MAC: 574f34b39f5745a97538d0bf3139910e5c246014fc77bf297cb0525504daf0d7

    """

    /// puttygen --ppk-param version=3,kdf=argon2i,memory=16,passes=1,parallelism=2, passphrase "secret"
    static let ppkP256V3Argon2i = """
    PuTTY-User-Key-File-3: ecdsa-sha2-nistp256
    Encryption: aes256-cbc
    Comment: v3 argon2i
    Public-Lines: 3
    AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFgXRKSE2DBQ
    tMCqE5M1JbU+GxaaDHJJvvgcm98SKaFmE/IMbQ2YwzzConMy1tmnruw89Aa+W2Gz
    OiSZYUzaGCU=
    Key-Derivation: Argon2i
    Argon2-Memory: 16
    Argon2-Passes: 1
    Argon2-Parallelism: 2
    Argon2-Salt: da8cf040f557c95ff9d8a2ada9497801
    Private-Lines: 1
    uiQVDi7o2mfdXRdhIfWGDaqNqgKH4EhTcwRNgnepugWM2+60wZvunpOC8Tz2admD
    Private-MAC: a1a6c5dc79870578be8e114ab475fae08b2567046989e154fbd9c7e0e197f4ed

    """

    // MARK: PEM vectors

    static let pkcs8Ed25519 = """
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEIIqOr0p3YNtxvHE+4JFgbBtIM+a7cXQSAC3bve3tpIF0
    -----END PRIVATE KEY-----
    """

    static let pkcs1RSA = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEAqIKtW9CbyJ6riNTIjxUJUSatRAv9WUptkI8+6Qs0FFVkorfY
    V8HYmjQCJj9fZBgD00Sk4tU9ndWZSjZLZEm7S/tO20/8mKVYEndDIw8xVnrl1kwU
    ve4IH1dVxXezBIni+ZabOBDYX/W97DplKfbjOaz3YSlWebLzSglOtP5GnW2G22XM
    r+Cz/Cn44hd3Wii2Wg89pD9mzqfHeBOXZnPC7D+ktFVnPOYZ1+vI1oqvbNTOL4ww
    2Etm3+/uFqE5ciA5aFjfmrU7JIvtJJ1WgEDN+fRcxQfm1HlbqqyxpQjeLAddB0vD
    PHVpFr0kGJjUX9QTGWHGfTJD8kulvAyIaqZAxwIDAQABAoIBAHuCRFQug3A5NBr3
    cwTEc27CfW6JpyjiD4pMI90ltAdPS5KkU3KHBx6HDihAfMddfrhD8OK9Tws3esJV
    J08bZ6daTEMczlSHpBTsyw2QXiY3r+wxGWbYZ6WpGpnAkTq7Ydx0EdK3LhCvioPx
    jSKD7anhZ/QUG2jZy84xIjowwUsywpR5PjAQMM6sOIzX/P0D94N1koUQAz20vw29
    A+bobwaJRptvXvLPxsi9qPAkYSUALsXBAjPwBE/AVX9dGWnYNBzdXVFwIIElzmPq
    4dSqDL3AriW3U0JyxYSY/bCJ/NTtHFeaGGNIwJrxPmZHrXKmoi+vo5vxC991MiXc
    F8oziaECgYEA0B1XeCH0znwX8ydG0YGVqnbKl91oREfi6j27+MVuDrvpvCrUy4ks
    ASsXUYP1UT0HLJUsvEmygGfC/HW/lA9/9zeFY1rgu8vOZSCjbZJKCEPxpPYJQamD
    wf3TlTzpHAi1OEWs55xR4I0Y8C3auK6XHh1tpfj/tvMB01++ZrWJghcCgYEAz0iE
    FhNdDU/disjNTUVDbVAosdmQsaZ2mj6su5sJF/+1RdCMon2lKhrgFgTC3SdI+Mxm
    zKykvbCS24i/G2lX2PtTmrKQu9xt6W27eK7in/VOZC/7mMyjfrjidRCJS6CkpFmk
    BFG1vJYwD8ktZi4mNjWoDuj+wT6TP2PdzKiY1NECgYAzDY+gk8vnP3/skU0JJh3e
    BGgsmw7x+SSMS/qpy1z1Vlm/ZE5xY8QcwUJmJ9XtSOhSooGn6vhUEaA+qHAH1UmS
    Dte1CN0qlJOcMUaGIaXxoyFLU2Pv7LK6yxa1fIy+6M/z7vu8kZdwW4yrlsQaHBJM
    O/HjDlNEwRZIkSs3LP9/nwKBgQCd2rakbSie+6RWjaczYj0AIVxsXKiBcai+vF4l
    HOMnAJgWy8Rd9ltynjbq7cNMUh+TQW5EDnIC91ZPk2seP/IjjvpTRAtO1YZqjyOG
    u4BgmpqRV6095xHXbose5XH5QyQ++PkcRPGm5aVCUE2flCOLgv8yI6PmnHXcf3wo
    4HhLEQKBgQCGrr/PRZfGXGDCQ6rjtI78n129RmodhPLFV7odc05xUdNLh/rh4qiO
    RNHVxlQrl97LhRwW8O4UeAb2JClwCHBAPXbjcaOzleXCQrcbPNIliEGANm/9H9O9
    sC4SieHCQ0R0jfIs+qEDjiVpEFAf8Osjddsi3EsA+5lrPWyDOcxfKQ==
    -----END RSA PRIVATE KEY-----
    """

    static let sec1P256 = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIEypLkpRWivNS31wDZgZm7g9uAFZ0JYD7S0us3F6EvzPoAoGCCqGSM49
    AwEHoUQDQgAEaTlzZ83l2gCj5DhloBdT8WnypHjTx5EzzvAQzR8/5HJmfMO/ufEf
    +0ogut22mxGgsd/jbhXi/LByJW1Xxso/aA==
    -----END EC PRIVATE KEY-----
    """

    static let pkcs8P256 = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgTKkuSlFaK81LfXAN
    mBmbuD24AVnQlgPtLS6zcXoS/M+hRANCAARpOXNnzeXaAKPkOGWgF1PxafKkeNPH
    kTPO8BDNHz/kcmZ8w7+58R/7SiC63babEaCx3+NuFeL8sHIlbVfGyj9o
    -----END PRIVATE KEY-----
    """

    // MARK: PuTTY

    @Test func parsesPPKVersion2Ed25519() throws {
        let pair = try SSHKeyPair.parse(Self.ppkEd25519V2)
        #expect(pair.keyType == "ssh-ed25519")
        #expect(pair.comment == "ppk-ed25519")
        #expect(pair.fingerprintSHA256 == "SHA256:HUi0uxQmJfAWIFopapDiTqOE/GmfVfTa7BQ3PZuZFjM")
        #expect(pair.canAuthenticate)
    }

    @Test func parsesEncryptedPPKVersion2() throws {
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHKeyPair.parse(Self.ppkEd25519V2Encrypted) }
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHKeyPair.parse(Self.ppkEd25519V2Encrypted, passphrase: "nope") }
        let pair = try SSHKeyPair.parse(Self.ppkEd25519V2Encrypted, passphrase: "secret")
        #expect(pair.fingerprintSHA256 == "SHA256:HUi0uxQmJfAWIFopapDiTqOE/GmfVfTa7BQ3PZuZFjM")
    }

    @Test func parsesPPKVersion2RSA() throws {
        let pair = try SSHKeyPair.parse(Self.ppkRSAV2)
        #expect(pair.keyType == "ssh-rsa")
        #expect(pair.bits == 2048)
        #expect(pair.fingerprintSHA256 == "SHA256:P5Nl/LIeboRcWLShlckW+Ci0py7G5W/gtCe9lYNx8WU")
        #expect(pair.canAuthenticate == false)
    }

    @Test func parsesPPKVersion3ECDSA() throws {
        let pair = try SSHKeyPair.parse(Self.ppkP256V3)
        #expect(pair.keyType == "ecdsa-sha2-nistp256")
        #expect(pair.comment == "ppk-p256")
        #expect(pair.fingerprintSHA256 == "SHA256:qE7n1Zn7wj0EUUqwBkAhjxcAOQbean4B1Jm13tEiYHc")
    }

    @Test func rejectsCorruptPPK() {
        let tampered = Self.ppkEd25519V2.replacingOccurrences(of: "Comment: ppk-ed25519", with: "Comment: tampered")
        #expect(throws: SSHKeyError.self) { try SSHKeyPair.parse(tampered) }
    }

    @Test func parsesEncryptedPPKVersion3WithArgon2() throws {
        let ed = try SSHKeyPair.parse(Self.ppkEd25519V3Argon2id, passphrase: "secret")
        #expect(ed.keyType == "ssh-ed25519")
        #expect(ed.fingerprintSHA256 == "SHA256:rMIyEqIiqtIZI/d/QDDiBldBs3u4cal3PIUSGUWTmDc")
        #expect(ed.comment == "v3 argon2 test")
        let ec = try SSHKeyPair.parse(Self.ppkP256V3Argon2i, passphrase: "secret")
        #expect(ec.keyType == "ecdsa-sha2-nistp256")
        #expect(ec.fingerprintSHA256 == "SHA256:xk/bPSjyqSDEpu09Aizqvoa1x5NwDk/uKRVca0gjHrc")
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHKeyPair.parse(Self.ppkEd25519V3Argon2id) }
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHKeyPair.parse(Self.ppkEd25519V3Argon2id, passphrase: "nope") }
    }

    // MARK: PEM

    @Test func parsesPKCS8Ed25519() throws {
        let pair = try SSHKeyPair.parse(Self.pkcs8Ed25519)
        #expect(pair.keyType == "ssh-ed25519")
        #expect(pair.openSSHPublicKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGBlxHxXdlwaJoTv3sNB6rV+li+ji+y3liahNwM7AVod")
        #expect(pair.fingerprintSHA256 == "SHA256:FCM/svrb1/u2w8PW4HAsCQvi8MTGTVoby1slPFgS1NI")
    }

    @Test func parsesPKCS1RSA() throws {
        let pair = try SSHKeyPair.parse(Self.pkcs1RSA)
        #expect(pair.keyType == "ssh-rsa")
        #expect(pair.bits == 2048)
        #expect(pair.fingerprintSHA256 == "SHA256:tr+c7MEvb94BCXVrQP1UU+7T7PWR2KLxVgT7c/HUmTU")
    }

    @Test func parsesECPEMInBothContainers() throws {
        let sec1 = try SSHKeyPair.parse(Self.sec1P256)
        let pkcs8 = try SSHKeyPair.parse(Self.pkcs8P256)
        #expect(sec1.fingerprintSHA256 == "SHA256:SfjBupvqjFIFt4lzwhasTGF9NJLowqU8ZeH6wd5VIV4")
        #expect(pkcs8.fingerprintSHA256 == sec1.fingerprintSHA256)
    }

    @Test func encryptedPEMIsReportedAsUnsupported() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----"
        #expect(throws: SSHKeyError.self) { try SSHKeyPair.parse(text, passphrase: "x") }
    }

    // MARK: Generation and OpenSSH round trips

    @Test(arguments: [SSHKeyPair.GenerationType.ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521])
    func generatedKeysRoundTripThroughOpenSSHFormat(type: SSHKeyPair.GenerationType) throws {
        let pair = try SSHKeyPair.generate(type, comment: "round-trip")
        #expect(pair.canAuthenticate)
        let plain = try pair.openSSHPrivateKey()
        let reparsed = try SSHKeyPair.parse(plain)
        #expect(reparsed.fingerprintSHA256 == pair.fingerprintSHA256)
        #expect(reparsed.comment == "round-trip")
        #expect(reparsed.openSSHPublicKey == pair.openSSHPublicKey)

        let encrypted = try pair.openSSHPrivateKey(passphrase: "hunter2", rounds: 2)
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHKeyPair.parse(encrypted) }
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHKeyPair.parse(encrypted, passphrase: "hunter3") }
        let decrypted = try SSHKeyPair.parse(encrypted, passphrase: "hunter2")
        #expect(decrypted.fingerprintSHA256 == pair.fingerprintSHA256)
    }

    @Test func generatedRSAKeyRoundTrips() throws {
        let pair = try SSHKeyPair.generate(.rsa3072, comment: "rsa-round-trip")
        #expect(pair.keyType == "ssh-rsa")
        #expect(pair.bits == 3072)
        #expect(pair.canAuthenticate == false)
        let reparsed = try SSHKeyPair.parse(try pair.openSSHPrivateKey())
        #expect(reparsed.fingerprintSHA256 == pair.fingerprintSHA256)
        #expect(reparsed.comment == "rsa-round-trip")
    }

    /// ssh-keygen must accept the files Tepfasonic writes.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
    func sshKeygenReadsExportedKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tepfa-keypair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, type) in [SSHKeyPair.GenerationType.ed25519, .ecdsaP384, .rsa3072].enumerated() {
            let pair = try SSHKeyPair.generate(type, comment: "exported")
            let plainURL = directory.appendingPathComponent("key\(index)")
            try pair.openSSHPrivateKey().write(to: plainURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plainURL.path)
            let fingerprint = try run("/usr/bin/ssh-keygen", ["-lf", plainURL.path])
            #expect(fingerprint.contains(pair.fingerprintSHA256), "ssh-keygen output: \(fingerprint)")

            let encryptedURL = directory.appendingPathComponent("key\(index).enc")
            try pair.openSSHPrivateKey(passphrase: "secret", rounds: 2).write(to: encryptedURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encryptedURL.path)
            let publicLine = try run("/usr/bin/ssh-keygen", ["-y", "-P", "secret", "-f", encryptedURL.path])
            #expect(publicLine.hasPrefix(pair.openSSHPublicKey.split(separator: " ").prefix(2).joined(separator: " ")), "ssh-keygen output: \(publicLine)")
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
