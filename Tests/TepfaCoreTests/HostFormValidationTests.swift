import Foundation
import Testing
@testable import TepfaCore

@Suite struct HostFormValidationTests {
    private func input(
        hostname: String = "example.com",
        username: String = "me",
        port: String = "22",
        authMethod: AuthMethod = .password,
        hasIdentity: Bool = false,
        jumpHostID: UUID? = nil,
        editedHostID: UUID? = nil
    ) -> HostFormValidation.Input {
        .init(hostname: hostname, username: username, port: port, authMethod: authMethod, hasIdentity: hasIdentity, jumpHostID: jumpHostID, editedHostID: editedHostID)
    }

    /// A new host has neither a jump host nor an id yet; that must not count as "its own jump host".
    @Test func newHostWithNoJumpHostIsValid() {
        let validation = HostFormValidation(input())
        #expect(validation.isValid)
        #expect(validation.problems.isEmpty)
    }

    @Test func editedHostWithNoJumpHostIsValid() {
        #expect(HostFormValidation(input(editedHostID: UUID())).isValid)
    }

    @Test func hostCannotJumpThroughItself() {
        let id = UUID()
        let validation = HostFormValidation(input(jumpHostID: id, editedHostID: id))
        #expect(validation.problems == ["A host cannot be its own jump host."])
        #expect(HostFormValidation(input(jumpHostID: id, editedHostID: UUID())).isValid)
        #expect(HostFormValidation(input(jumpHostID: id)).isValid)
    }

    @Test func requiredFields() {
        #expect(HostFormValidation(input(hostname: "  ")).problems == ["Enter a hostname or IP address."])
        #expect(HostFormValidation(input(username: "")).problems == ["Enter a username."])
        #expect(HostFormValidation(input(port: "0")).problems == ["The port must be a number from 1 to 65535."])
        #expect(HostFormValidation(input(port: "70000")).problems.count == 1)
        #expect(HostFormValidation(input(port: " 2222 ")).isValid)
    }

    @Test func identityIsNeededForKeyAuthentication() {
        let missing = HostFormValidation(input(authMethod: .privateKey, hasIdentity: false))
        #expect(missing.problems == ["Choose an identity, or switch the method to “Ask for a password”."])
        #expect(HostFormValidation(input(authMethod: .privateKey, hasIdentity: true)).isValid)
        #expect(HostFormValidation(input(authMethod: .password, hasIdentity: false)).isValid)
    }

    @Test func proxyFieldsOnlyMatterWhenEnabled() {
        var fields = input()
        fields.proxyEnabled = false
        #expect(HostFormValidation(fields).isValid)
        fields.proxyEnabled = true
        #expect(HostFormValidation(fields).problems == ["Enter the proxy host.", "The proxy port must be a number from 1 to 65535."])
        fields.proxyHost = "proxy.example.com"
        fields.proxyPort = "3128"
        #expect(HostFormValidation(fields).isValid)
    }

    @Test func problemsFollowTheFormOrder() {
        let everything = HostFormValidation(.init(hostname: "", username: "", port: "x", authMethod: .privateKey, hasIdentity: false, proxyEnabled: true))
        #expect(everything.problems.count == 6)
        #expect(everything.problems.first == "Enter a hostname or IP address.")
    }

    @Test func portParsing() {
        #expect(HostFormValidation.port("22") == 22)
        #expect(HostFormValidation.port("65535") == 65535)
        #expect(HostFormValidation.port("65536") == nil)
        #expect(HostFormValidation.port("") == nil)
        #expect(HostFormValidation.port("ssh") == nil)
    }
}
