import Foundation
import SwiftData

/// Moving hosts between groups and ordering them: the sidebar's drag and drop,
/// the context menus and the group editor all go through here so the
/// `sortOrder` numbering stays consistent.
public enum HostGrouping {
    /// The order of `ordered` after `moving` is placed at `index`, with any
    /// earlier occurrences of the moved ids removed first. `index` is a
    /// position in `ordered` as it was before the move, so dragging an item
    /// below its own old place lands where the user dropped it.
    public static func inserting(_ moving: [UUID], into ordered: [UUID], at index: Int) -> [UUID] {
        let movingSet = Set(moving)
        let unique = moving.enumerated().filter { pair in moving.firstIndex(of: pair.element) == pair.offset }.map(\.element)
        let remaining = ordered.filter { !movingSet.contains($0) }
        let removedBefore = ordered.prefix(max(index, 0)).filter { movingSet.contains($0) }.count
        let target = min(max(index - removedBefore, 0), remaining.count)
        var result = remaining
        result.insert(contentsOf: unique, at: target)
        return result
    }

    /// Hosts of one group (nil = ungrouped) in sidebar order.
    public static func members(of group: HostGroup?, in hosts: [SSHHost]) -> [SSHHost] {
        hosts.filter { $0.group?.uuid == group?.uuid }.sorted(by: sidebarOrder)
    }

    /// Sidebar order: `sortOrder`, then name.
    public static func sidebarOrder(_ a: SSHHost, _ b: SSHHost) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Groups in sidebar order: `sortOrder`, then name.
    public static func sidebarOrder(_ a: HostGroup, _ b: HostGroup) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Puts `moving` into `group` (nil = no group) at `index` among the group's
    /// current members, or at the end when `index` is nil, and renumbers that
    /// group. Hosts that leave another group keep the rest of that group's
    /// order intact.
    public static func move(_ moving: [SSHHost], to group: HostGroup?, at index: Int? = nil, among hosts: [SSHHost]) {
        let members = members(of: group, in: hosts)
        let order = inserting(moving.map(\.uuid), into: members.map(\.uuid), at: index ?? members.count)
        var byID: [UUID: SSHHost] = [:]
        for host in members + moving { byID[host.uuid] = host }
        for host in moving where host.group?.uuid != group?.uuid { host.group = group }
        for (position, id) in order.enumerated() {
            if let host = byID[id], host.sortOrder != position { host.sortOrder = position }
        }
    }

    /// Reorders hosts inside one group from a list move.
    public static func reorder(_ members: [SSHHost], fromOffsets source: IndexSet, toOffset destination: Int) {
        renumber(moving(members, fromOffsets: source, toOffset: destination))
    }

    /// `Array.move(fromOffsets:toOffset:)` without SwiftUI: `destination` is a
    /// position in the array before the move, as a list's move callback gives it.
    public static func moving<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let moved = source.compactMap { items.indices.contains($0) ? items[$0] : nil }
        let removedBefore = source.filter { $0 < destination }.count
        var result = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let target = min(max(destination - removedBefore, 0), result.count)
        result.insert(contentsOf: moved, at: target)
        return result
    }

    /// Writes positions 0… to the given hosts in that order.
    public static func renumber(_ hosts: [SSHHost]) {
        for (position, host) in hosts.enumerated() where host.sortOrder != position { host.sortOrder = position }
    }

    /// Writes positions 0… to the given groups in that order.
    public static func renumber(_ groups: [HostGroup]) {
        for (position, group) in groups.enumerated() where group.sortOrder != position { group.sortOrder = position }
    }

    /// Moves a group one place up (`-1`) or down (`+1`) in the sidebar.
    /// Returns false when it is already at that end.
    @discardableResult
    public static func move(_ group: HostGroup, by offset: Int, among groups: [HostGroup]) -> Bool {
        var order = groups.sorted(by: sidebarOrder)
        guard let index = order.firstIndex(where: { $0.uuid == group.uuid }) else { return false }
        let target = index + offset
        guard order.indices.contains(target) else { return false }
        order.swapAt(index, target)
        renumber(order)
        return true
    }

    /// The sort order for a new group or host so it lands last.
    public static func nextSortOrder(after groups: [HostGroup]) -> Int {
        (groups.map(\.sortOrder).max() ?? -1) + 1
    }

    public static func nextSortOrder(after hosts: [SSHHost]) -> Int {
        (hosts.map(\.sortOrder).max() ?? -1) + 1
    }
}
