import Foundation
import Testing
@testable import TepfaCore

@Suite struct SnippetVariablesTests {
    @Test func findsDistinctVariablesInOrderWithDefaults() {
        let vars = SnippetVariables.variables(in: "ssh {{ user }}@{{host}} -p {{port:22}} && echo {{user}}")
        #expect(vars.map(\.name) == ["user", "host", "port"])
        #expect(vars[2].defaultValue == "22")
        #expect(vars[0].defaultValue == nil)
    }

    @Test func substitutesValuesAndFallsBackToDefaults() {
        let text = "docker logs -f {{container}} --tail {{lines:100}} {{missing}}"
        let result = SnippetVariables.substitute(text, values: ["container": "web"])
        #expect(result == "docker logs -f web --tail 100 ")
    }

    @Test func ignoresMalformedPlaceholders() {
        #expect(SnippetVariables.variables(in: "echo {{ 1bad }} {{}} {{ok}}").map(\.name) == ["ok"])
        #expect(SnippetVariables.substitute("{{ }}", values: [:]) == "{{ }}")
    }

    @Test func defaultsMayContainSpaces() {
        let vars = SnippetVariables.variables(in: "git commit -m \"{{message:work in progress}}\"")
        #expect(vars.first?.defaultValue == "work in progress")
        #expect(SnippetVariables.substitute("{{message:work in progress}}", values: [:]) == "work in progress")
    }
}
