import Foundation
import Testing
@testable import TepfaSSH

// Keys generated with the system ssh-keygen; fingerprints from `ssh-keygen -lf`.
@Suite struct PrivateKeyParsingTests {
    static let ed25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBAsTaDzWsN0KQEQ7kaPcG7ALCn1ZUHbiuNPzKi5TrgfgAAAJi/opObv6KT
    mwAAAAtzc2gtZWQyNTUxOQAAACBAsTaDzWsN0KQEQ7kaPcG7ALCn1ZUHbiuNPzKi5Trgfg
    AAAECLyod+A9caOIGsbMaZy9hSCrNTcO3gKZvn7tTjRt4nH0CxNoPNaw3QpARDuRo9wbsA
    sKfVlQduK40/MqLlOuB+AAAAEnRlcGZhLXRlc3QtZWQyNTUxOQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let p256 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQREJ4+oAx8HMm5OvkRBBerqlm0n6MV7
    yM5o/HFAdziX0ZAAcZLcpzyrkZphC7QAuPZKuhhS9Tq9nWvNwmEr2gBtAAAAqEGFDJ5BhQ
    yeAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEQnj6gDHwcybk6+
    REEF6uqWbSfoxXvIzmj8cUB3OJfRkABxktynPKuRmmELtAC49kq6GFL1Or2da83CYSvaAG
    0AAAAgHwWnaEtex4RUR0eKPgAMSoPK1FSD/Xyq0M0gMhfeQiUAAAAPdGVwZmEtdGVzdC1w
    MjU2AQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let p384 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
    1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQQqjwunJfUH/74frUpJEW0fnXN181K9
    uUpBjsO+FvLkj6yU5odjGl901JLMZJScdWwGCWLVPqqvtKJDPN6rXkEQRWkO2KbxfaTF/P
    uyMoNI/s8GtytO84RIuBXNclaq4GkAAADYeDVLaXg1S2kAAAATZWNkc2Etc2hhMi1uaXN0
    cDM4NAAAAAhuaXN0cDM4NAAAAGEEKo8LpyX1B/++H61KSRFtH51zdfNSvblKQY7Dvhby5I
    +slOaHYxpfdNSSzGSUnHVsBgli1T6qr7SiQzzeq15BEEVpDtim8X2kxfz7sjKDSP7PBrcr
    TvOESLgVzXJWquBpAAAAMQCi+Mrn9aW/XcRjSTuXRIiIENJRplMQfwLT/LJg8vWGweB6Df
    tDv60MFuTVc588wlkAAAAPdGVwZmEtdGVzdC1wMzg0
    -----END OPENSSH PRIVATE KEY-----
    """

    static let p521 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
    1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQB/r6mYxAHsYgOSDobCR3WXys8LWo9
    rl1IKinhJRMsgwpkvR9bpd3hLET3D5U9utJX+4eh4PmEKvGg8fS7fgBAfFcA1mZMMthaLp
    u3ImH3UfC0BpVckjnL8hDRss0mKF6dN/Bd0jPO9J6QNWsrhLew0xGOZm2lsi6yFbaXu++P
    hXy5kgQAAAEQXBwkG1wcJBsAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
    AAAIUEAf6+pmMQB7GIDkg6Gwkd1l8rPC1qPa5dSCop4SUTLIMKZL0fW6Xd4SxE9w+VPbrS
    V/uHoeD5hCrxoPH0u34AQHxXANZmTDLYWi6btyJh91HwtAaVXJI5y/IQ0bLNJihenTfwXd
    IzzvSekDVrK4S3sNMRjmZtpbIushW2l7vvj4V8uZIEAAAAQgG61P5Ps3DFFTOmyMRkDwcm
    sySBfwV60/FwZEk0jZWOHLAhu4jYaB6cu69qSFhChWUA5YbmCbpfQsqMcayQNpMzKgAAAA
    90ZXBmYS10ZXN0LXA1MjEBAgM=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let encrypted = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBfEKSS4T
    inS4C4ifMAxGNjAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIM8Gg26l3HPSsL8M
    4f4kg0Y4hC9V6V28rCJQoHZdUeU0AAAAoM6XFMBRVNg8in34OczEBRPfv8y01chNj71Q/C
    1cl/2VgmUjG6z0ZRmGC5gHRbtzaN7XKo9p0p+GPboYcxNYsXdlQ197x+FXcZmFaVZlfuQC
    tzkEawNLWIHfDB5peVi4pEBOGDluR4dvxoeEcj+EPC6indRYFHfrKrj6/C/w14jI9zx0LY
    KIT4VV8MTGUviTVMlvJeTLtQOzsyCtXUGMHZo=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let rsa = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAQEAw0fVbCNkfqDlAUOmn0EP/fETN42tcvMVd8FijEwgi6wnHm1wpVVy
    NGLAgPgzzWD2pdNLlLNkO9uxUkVicuVoiBHwcW0ssjxg2O2PKHlf27sE0Ek2gUhMLbXoLb
    2rCzd6gXsUicbeprVe/kBpo5GuDEYsGInRjT4vt8PC9LVqUlJ16LdojY46TJp71+ZAQm7x
    N5qHVDvms6BNBohyDT/LTOHhhr9ejt0kGmos0c/lf2k3VlNjedfV72SPvSPnA2ys45AwcT
    a32ECv04OwD/jcdogX8jI0Re0yRuSxSSvH+U049GP286keySHUE6NJZsFQJj0SB8r2fwuB
    aVD1b/arUwAAA8j+noQM/p6EDAAAAAdzc2gtcnNhAAABAQDDR9VsI2R+oOUBQ6afQQ/98R
    M3ja1y8xV3wWKMTCCLrCcebXClVXI0YsCA+DPNYPal00uUs2Q727FSRWJy5WiIEfBxbSyy
    PGDY7Y8oeV/buwTQSTaBSEwttegtvasLN3qBexSJxt6mtV7+QGmjka4MRiwYidGNPi+3w8
    L0tWpSUnXot2iNjjpMmnvX5kBCbvE3modUO+azoE0GiHINP8tM4eGGv16O3SQaaizRz+V/
    aTdWU2N519XvZI+9I+cDbKzjkDBxNrfYQK/Tg7AP+Nx2iBfyMjRF7TJG5LFJK8f5TTj0Y/
    bzqR7JIdQTo0lmwVAmPRIHyvZ/C4FpUPVv9qtTAAAAAwEAAQAAAQALOLeE7Uu7ExfVyMNs
    Z1q55v6JtLSA5IMZTJ2THlTIce4Vi4hrl8tmQz54qsqfRLEnukqfkudxoSBBcAdGPvSQzS
    cZ/YISA/I0xQHy+3aMs+SE65AcQcFO5yMebcXEcT2y7xWxDSKCRe3dgmoPojF0NxwVlOXb
    zfUEBFXRphMkA8s/0m3/ao3phcPsN11+hCqE642LxZcwzaP3p5wwF4wLr/2LK4nBwLx7zr
    Ipq4ZcbcJkJVt+cfKEs5GZpkn/aIA/Yy8kHvARFXb8B3YSiCIbL5AofRAEAC9igQTKb5F0
    BIicI5f4Hb8Ltd2Jde7rhYNObdOvRvu+et46EdJXy5aRAAAAgQDN5r76qYWLp/TKN6o+FC
    PhbY4pGl+Rr5VzyXBRXOQ1N/PektdX5FiApowsQY8wTW1pj5adQXh3VI11c6K7vswLHiCU
    knxmW1hCrZtG+hAVb0KYE/XKgZY2XCsYUK5RPseVTuQdc5tx5KgPSV6kQmE92ZC90JWSCl
    nhTRddoM/CpwAAAIEA9WjS6G+jdHQ4qZTuoK4sD6pLqIj1I3Tuja3wmWca5RGE9agni79A
    dQDgUQgfyfK6pGxM1v01maG68r7HzI/1NMwKN8K295yWg2C7ZXIOyFgMBenwhg3EseF10T
    9TaIkffhFjwog2cd74Zoj8Y1yJJjJtH3dFN4K98J/aKQMGwkUAAACBAMu1NUTaCfOoATI+
    7+TJk/mKuFadYgYbbQnleC4MQ1fw266clQqZmuaIH9EomsLGdDG2yc1ZmIRzUNC1fxE6D3
    z+aR0HRWoJh6MItWMWw0nd7ehtUqPzWiqQGFIj7IBd9jfrAhnK6A9hvR/SeKYLAXRSoXGb
    FNXcuGB1tqsknVy3AAAADnRlcGZhLXRlc3QtcnNhAQIDBA==
    -----END OPENSSH PRIVATE KEY-----
    """

    @Test func parsesEd25519() throws {
        let key = try SSHPrivateKey.parse(Self.ed25519)
        #expect(key.keyType == .ed25519)
        #expect(key.comment == "tepfa-test-ed25519")
        #expect(key.openSSHPublicKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECxNoPNaw3QpARDuRo9wbsAsKfVlQduK40/MqLlOuB+")
        #expect(key.fingerprintSHA256 == "SHA256:7vwtpeRqyDuurDQlkywB2udH6UcuoaxJDtOfzrqqpFU")
    }

    @Test func parsesECDSAP256() throws {
        let key = try SSHPrivateKey.parse(Self.p256)
        #expect(key.keyType == .ecdsaP256)
        #expect(key.comment == "tepfa-test-p256")
        #expect(key.openSSHPublicKey == "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEQnj6gDHwcybk6+REEF6uqWbSfoxXvIzmj8cUB3OJfRkABxktynPKuRmmELtAC49kq6GFL1Or2da83CYSvaAG0=")
        #expect(key.fingerprintSHA256 == "SHA256:kwVNs9qyAQqdDkT49aBBmgN9XdM7D2Mq5IfX8IFyk5I")
    }

    @Test func parsesECDSAP384() throws {
        let key = try SSHPrivateKey.parse(Self.p384)
        #expect(key.keyType == .ecdsaP384)
        #expect(key.fingerprintSHA256 == "SHA256:F/46pNrrGAsYD1sT9pZFJuDFjsbvjiTTGSH776JIr+U")
    }

    @Test func parsesECDSAP521() throws {
        let key = try SSHPrivateKey.parse(Self.p521)
        #expect(key.keyType == .ecdsaP521)
        #expect(key.fingerprintSHA256 == "SHA256:JqklqAW2O2uPh/H0YQtMB+8lRZLhiAat39vpnDddSZQ")
    }

    @Test func encryptedKeysNeedThePassphrase() throws {
        #expect(throws: SSHKeyError.passphraseRequired) {
            try SSHPrivateKey.parse(Self.encrypted)
        }
        #expect(throws: SSHKeyError.wrongPassphrase) {
            try SSHPrivateKey.parse(Self.encrypted, passphrase: "wrong")
        }
        let key = try SSHPrivateKey.parse(Self.encrypted, passphrase: "secret")
        #expect(key.keyType == .ed25519)
        #expect(key.comment == "tepfa-test-enc")
        #expect(key.fingerprintSHA256 == "SHA256:1CLaR56+r85N/Ym3Nkm4xdSEhmSoCbusgYYmwi12iGE")
    }

    @Test func rsaKeysParseButCannotAuthenticate() throws {
        let pair = try SSHKeyPair.parse(Self.rsa)
        #expect(pair.keyType == "ssh-rsa")
        #expect(pair.comment == "tepfa-test-rsa")
        #expect(pair.bits == 2048)
        #expect(pair.canAuthenticate == false)
        #expect(throws: SSHKeyError.cannotAuthenticate("ssh-rsa")) {
            try SSHPrivateKey.parse(Self.rsa)
        }
        #expect(throws: SSHKeyError.self) {
            try SSHPrivateKey.parse("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----")
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: SSHKeyError.self) { try SSHPrivateKey.parse("not a key") }
        #expect(throws: SSHKeyError.self) { try SSHPrivateKey.parse("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----") }
        // Truncated body: the armor is intact but the payload is cut off mid-structure.
        let truncated = Self.ed25519.replacingOccurrences(of: "sKfVlQduK40/MqLlOuB+AAAAEnRlcGZhLXRlc3QtZWQyNTUxOQECAw==", with: "")
        #expect(throws: SSHKeyError.self) { try SSHPrivateKey.parse(truncated) }
    }

    @Test func missingFileIsReported() {
        #expect(throws: SSHKeyError.unreadableFile("/nonexistent/id_ed25519")) {
            try SSHPrivateKey.load(from: URL(fileURLWithPath: "/nonexistent/id_ed25519"))
        }
    }
}
