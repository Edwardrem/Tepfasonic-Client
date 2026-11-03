import Foundation
import Testing
import TepfaCore
@testable import TepfaTerminal

@Suite struct TypedLineTrackerTests {
    @Test func followsPlainTypingAndEnter() {
        var tracker = TypedLineTracker()
        #expect(tracker.consume(ArraySlice("ls -la".utf8)) == .none)
        #expect(tracker.text == "ls -la")
        #expect(tracker.consume(ArraySlice("\r".utf8)) == .submitted("ls -la"))
        #expect(tracker.text == "")
    }

    @Test func backspaceControlUAndControlW() {
        var tracker = TypedLineTracker()
        _ = tracker.consume(ArraySlice("git statsu".utf8))
        _ = tracker.consume([0x7f, 0x7f])
        _ = tracker.consume(ArraySlice("us".utf8))
        #expect(tracker.text == "git status")
        _ = tracker.consume([0x17])
        #expect(tracker.text == "git ")
        _ = tracker.consume([0x15])
        #expect(tracker.text == "")
        #expect(tracker.isReliable)
    }

    @Test func arrowKeysMakeTheLineUnreliableUntilEnter() {
        var tracker = TypedLineTracker()
        _ = tracker.consume(ArraySlice("echo".utf8))
        _ = tracker.consume(ArraySlice("\u{1b}[A".utf8))
        #expect(!tracker.isReliable)
        #expect(tracker.consume([0x0d]) == .cancelled)
        #expect(tracker.isReliable)
        #expect(tracker.text == "")
    }

    @Test func controlCCancelsAndEmptyEnterIsNothing() {
        var tracker = TypedLineTracker()
        _ = tracker.consume(ArraySlice("sleep 100".utf8))
        #expect(tracker.consume([0x03]) == .cancelled)
        #expect(tracker.consume([0x0d]) == .none)
    }

    @Test func decodesUTF8AcrossChunks() {
        var tracker = TypedLineTracker()
        let bytes = Array("echo é".utf8)
        _ = tracker.consume(bytes[..<(bytes.count - 1)][...])
        _ = tracker.consume(bytes[(bytes.count - 1)...])
        #expect(tracker.text == "echo é")
    }
}

@Suite struct SemanticPromptActionTests {
    @Test func parsesOSC133Payloads() {
        #expect(SemanticPromptAction(payload: Array("A".utf8)) == .promptStart)
        #expect(SemanticPromptAction(payload: Array("B".utf8)) == .inputStart)
        #expect(SemanticPromptAction(payload: Array("C".utf8)) == .commandStart)
        #expect(SemanticPromptAction(payload: Array("D;127".utf8)) == .commandEnd(127))
        #expect(SemanticPromptAction(payload: Array("D".utf8)) == .commandEnd(nil))
        #expect(SemanticPromptAction(payload: Array("Z".utf8)) == nil)
    }

    @Test func parsesWorkingDirectoryReports() {
        #expect(WorkingDirectoryReport.path(from: Array("file://box/home/me/src".utf8)) == "/home/me/src")
        #expect(WorkingDirectoryReport.path(from: Array("file://box/tmp/a%20b".utf8)) == "/tmp/a b")
        #expect(WorkingDirectoryReport.path(from: Array("http://x/y".utf8)) == nil)
    }
}

@Suite struct ShellIntegrationScriptTests {
    @Test func recognisesSupportedLoginShells() {
        #expect(ShellIntegration.supports(loginShell: "/bin/zsh\n"))
        #expect(ShellIntegration.supports(loginShell: "/usr/bin/bash"))
        #expect(!ShellIntegration.supports(loginShell: "/usr/bin/fish"))
        #expect(!ShellIntegration.supports(loginShell: ""))
    }

    @Test func installLineErasesExactlyTheRowsItsEchoUsed() {
        for cols in [40, 80, 132, 200] {
            for cursor in [2, 17, 38] {
                let line = ShellIntegration.installLine(cursorColumn: cursor, columns: cols)
                let total = cursor + line.utf8.count
                #expect(total % cols != 0)
                let expectedRows = total / cols + 1
                #expect(line.hasSuffix("printf '\\033[\(expectedRows)A\\033[J'"), "cols \(cols) cursor \(cursor): \(line.suffix(30))")
                #expect(line.hasPrefix(" if [ -n \"$ZSH_VERSION\" ]"))
                #expect(!line.contains("\n"))
            }
        }
    }

    @Test func hooksUseOnlyPortableSyntax() {
        // Both branches must be valid for sh-style parsers: balanced braces and quotes.
        for script in [ShellIntegration.bash, ShellIntegration.zsh] {
            #expect(script.filter { $0 == "{" }.count == script.filter { $0 == "}" }.count)
            #expect(script.filter { $0 == "'" }.count % 2 == 0)
            #expect(script.contains("133;A"))
            #expect(script.contains("133;B"))
            #expect(script.contains("133;C"))
            #expect(script.contains("133;D;%s"))
        }
    }
}

@Suite struct HostDescriptorCodingTests {
    @Test func decodesSnapshotsWrittenBeforeStartupCommandExisted() throws {
        let json = """
        {"id":"8F6D2C3E-5A9B-4C1D-8E2F-1A2B3C4D5E6F","name":"old","hostname":"h","port":22,"username":"u","authMethod":"password","autoReconnect":true,"isTransient":true}
        """
        let descriptor = try JSONDecoder().decode(HostDescriptor.self, from: Data(json.utf8))
        #expect(descriptor.startupCommand == nil)
        #expect(descriptor.shellIntegration == .automatic)
        #expect(descriptor.isTransient)
    }

    @Test func roundTripsNewFields() throws {
        let descriptor = HostDescriptor(name: "n", hostname: "h", username: "u", startupCommand: "tmux a", shellIntegration: .disabled)
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(HostDescriptor.self, from: data)
        #expect(decoded == descriptor)
    }
}
