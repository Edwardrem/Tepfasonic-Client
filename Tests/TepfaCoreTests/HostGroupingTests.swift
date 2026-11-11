import Foundation
import SwiftData
import Testing
@testable import TepfaCore

@Suite struct HostGroupingOrderTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func insertsAtTheDropIndexAfterRemovingTheMovedItems() {
        // Moving `a` below `c` in [a b c d]: the drop index 3 counts `a` itself.
        #expect(HostGrouping.inserting([a], into: [a, b, c, d], at: 3) == [b, c, a, d])
        // Moving `d` to the top.
        #expect(HostGrouping.inserting([d], into: [a, b, c, d], at: 0) == [d, a, b, c])
        // Coming from another group: nothing to remove, lands at the index.
        let e = UUID()
        #expect(HostGrouping.inserting([e], into: [a, b], at: 1) == [a, e, b])
        // Past the end and negative indexes clamp; duplicates collapse.
        #expect(HostGrouping.inserting([e, e], into: [a, b], at: 99) == [a, b, e])
        #expect(HostGrouping.inserting([e], into: [], at: -2) == [e])
        // The SwiftUI-style move used for reordering inside a group.
        #expect(HostGrouping.moving([a, b, c, d], fromOffsets: IndexSet(integer: 0), toOffset: 3) == [b, c, a, d])
        #expect(HostGrouping.moving([a, b, c, d], fromOffsets: IndexSet(integer: 3), toOffset: 0) == [d, a, b, c])
        #expect(HostGrouping.moving([a, b, c, d], fromOffsets: IndexSet([0, 2]), toOffset: 4) == [b, d, a, c])
        // Several items keep their drag order.
        #expect(HostGrouping.inserting([c, a], into: [a, b, c, d], at: 4) == [b, d, c, a])
    }
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(TepfaSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
}

@Suite @MainActor struct HostGroupingModelTests {
    @Test func movesHostsBetweenGroupsAndRenumbers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lab = HostGroup(name: "Lab", sortOrder: 0)
        let prod = HostGroup(name: "Production", sortOrder: 1)
        context.insert(lab)
        context.insert(prod)
        let web = SSHHost(name: "web", hostname: "web", username: "u", sortOrder: 0, group: lab)
        let db = SSHHost(name: "db", hostname: "db", username: "u", sortOrder: 1, group: lab)
        let cache = SSHHost(name: "cache", hostname: "cache", username: "u", sortOrder: 2, group: lab)
        let loose = SSHHost(name: "loose", hostname: "loose", username: "u", sortOrder: 0)
        for host in [web, db, cache, loose] { context.insert(host) }
        let all = [web, db, cache, loose]

        // Drag `db` into Production: it joins at the end, Lab closes the gap.
        HostGrouping.move([db], to: prod, among: all)
        #expect(db.group?.uuid == prod.uuid)
        #expect(HostGrouping.members(of: lab, in: all).map(\.name) == ["web", "cache"])
        #expect(HostGrouping.members(of: prod, in: all).map(\.name) == ["db"])

        // Drop `loose` at the top of Production.
        HostGrouping.move([loose], to: prod, at: 0, among: all)
        #expect(HostGrouping.members(of: prod, in: all).map(\.name) == ["loose", "db"])
        #expect(loose.sortOrder == 0 && db.sortOrder == 1)

        // Reorder inside Lab, then ungroup `web`.
        HostGrouping.reorder(HostGrouping.members(of: lab, in: all), fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(HostGrouping.members(of: lab, in: all).map(\.name) == ["cache", "web"])
        HostGrouping.move([web], to: nil, among: all)
        #expect(web.group == nil)
        #expect(HostGrouping.members(of: nil, in: all).map(\.name) == ["web"])
        #expect(HostGrouping.members(of: lab, in: all).map(\.name) == ["cache"])
        try context.save()
    }

    @Test func movesGroupsUpAndDownWithinBounds() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let groups = ["One", "Two", "Three"].enumerated().map { HostGroup(name: $0.element, sortOrder: $0.offset) }
        for group in groups { context.insert(group) }
        #expect(HostGrouping.move(groups[0], by: -1, among: groups) == false)
        #expect(HostGrouping.move(groups[2], by: 1, among: groups) == false)
        #expect(HostGrouping.move(groups[2], by: -1, among: groups))
        #expect(groups.sorted(by: HostGrouping.sidebarOrder).map(\.name) == ["One", "Three", "Two"])
        #expect(HostGrouping.move(groups[0], by: 1, among: groups))
        #expect(groups.sorted(by: HostGrouping.sidebarOrder).map(\.name) == ["Three", "One", "Two"])
        #expect(HostGrouping.nextSortOrder(after: groups) == 3)
        #expect(HostGrouping.nextSortOrder(after: [SSHHost]()) == 0)
    }
}
