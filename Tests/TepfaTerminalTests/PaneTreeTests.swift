import Foundation
import Testing
@testable import TepfaTerminal

@Suite struct PaneTreeTests {
    @Test func splitAndRemove() {
        let a = UUID(), sa = UUID(), sb = UUID(), sc = UUID()
        var tree: PaneNode = .leaf(id: a, sessionID: sa)
        let b = UUID()
        tree = tree.splitting(leaf: a, axis: .horizontal, newLeafID: b, sessionID: sb)
        #expect(tree.leafIDs == [a, b])
        #expect(tree.sessionIDs == [sa, sb])

        let c = UUID()
        tree = tree.splitting(leaf: b, axis: .vertical, newLeafID: c, sessionID: sc)
        #expect(tree.leafIDs == [a, b, c])
        #expect(tree.sessionID(ofLeaf: c) == sc)
        #expect(tree.leafID(ofSession: sb) == b)

        // Removing b collapses the vertical split so c takes its place.
        let withoutB = tree.removing(leaf: b)
        #expect(withoutB?.leafIDs == [a, c])
        guard case .split(_, let axis, _, _, _) = withoutB else { Issue.record("expected a split"); return }
        #expect(axis == .horizontal)

        #expect(withoutB?.removing(leaf: a)?.leafIDs == [c])
        #expect(withoutB?.removing(leaf: a)?.removing(leaf: c) == nil)
        #expect(tree.removing(leaf: UUID())?.leafIDs == [a, b, c])
    }

    @Test func framesAndNeighbors() {
        let left = UUID(), topRight = UUID(), bottomRight = UUID()
        let tree: PaneNode = .split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: left, sessionID: UUID()),
            second: .split(id: UUID(), axis: .vertical,
                           first: .leaf(id: topRight, sessionID: UUID()),
                           second: .leaf(id: bottomRight, sessionID: UUID()),
                           fraction: 0.5),
            fraction: 0.5)

        let frames = tree.leafFrames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[left] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(frames[topRight] == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(frames[bottomRight] == CGRect(x: 50, y: 50, width: 50, height: 50))

        #expect(tree.neighbor(of: left, direction: .right) == topRight)
        #expect(tree.neighbor(of: left, direction: .left) == nil)
        #expect(tree.neighbor(of: topRight, direction: .down) == bottomRight)
        #expect(tree.neighbor(of: bottomRight, direction: .up) == topRight)
        #expect(tree.neighbor(of: bottomRight, direction: .left) == left)
        #expect(tree.neighbor(of: topRight, direction: .right) == nil)
    }

    @Test func fractionIsClampedAndScoped() {
        let splitID = UUID()
        let tree: PaneNode = .split(id: splitID, axis: .horizontal, first: .leaf(id: UUID(), sessionID: UUID()), second: .leaf(id: UUID(), sessionID: UUID()), fraction: 0.5)
        guard case .split(_, _, _, _, let fraction) = tree.settingFraction(0.01, forSplit: splitID) else { Issue.record("expected split"); return }
        #expect(fraction == 0.1)
        guard case .split(_, _, _, _, let unchanged) = tree.settingFraction(0.8, forSplit: UUID()) else { Issue.record("expected split"); return }
        #expect(unchanged == 0.5)
    }

    @Test func roundTripsThroughJSON() throws {
        let tree: PaneNode = .split(id: UUID(), axis: .vertical, first: .leaf(id: UUID(), sessionID: UUID()), second: .leaf(id: UUID(), sessionID: UUID()), fraction: 0.3)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == tree)
    }

    @Test func quickConnectParsing() {
        let full = HostDescriptor.quickConnect("deploy@example.com:2222")
        #expect(full?.username == "deploy")
        #expect(full?.hostname == "example.com")
        #expect(full?.port == 2222)
        #expect(full?.isTransient == true)
        #expect(full?.name == "example.com:2222")

        let bare = HostDescriptor.quickConnect("10.0.0.5", defaultUsername: "me")
        #expect(bare?.username == "me")
        #expect(bare?.port == 22)
        #expect(bare?.name == "10.0.0.5")

        #expect(HostDescriptor.quickConnect("ssh://root@box")?.username == "root")
        #expect(HostDescriptor.quickConnect("") == nil)
        #expect(HostDescriptor.quickConnect("host:notaport") == nil)
        #expect(HostDescriptor.quickConnect("two words") == nil)
    }
}
