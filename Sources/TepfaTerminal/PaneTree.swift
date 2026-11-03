import CoreGraphics
import Foundation

public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Children side by side, left and right.
    case horizontal
    /// Children stacked, top and bottom.
    case vertical
}

public enum PaneDirection: Sendable {
    case left, right, up, down
}

/// A binary tree of terminal panes. Splits nest as deep as needed.
public indirect enum PaneNode: Codable, Hashable, Sendable, Identifiable {
    case leaf(id: UUID, sessionID: UUID)
    case split(id: UUID, axis: SplitAxis, first: PaneNode, second: PaneNode, fraction: Double)

    public var id: UUID {
        switch self {
        case .leaf(let id, _): id
        case .split(let id, _, _, _, _): id
        }
    }

    /// Leaves in layout order (left to right, top to bottom).
    public var leaves: [(id: UUID, sessionID: UUID)] {
        switch self {
        case .leaf(let id, let sessionID): [(id, sessionID)]
        case .split(_, _, let first, let second, _): first.leaves + second.leaves
        }
    }

    public var leafIDs: [UUID] { leaves.map(\.id) }
    public var sessionIDs: [UUID] { leaves.map(\.sessionID) }
    public var isLeaf: Bool { if case .leaf = self { return true } else { return false } }

    public func sessionID(ofLeaf leafID: UUID) -> UUID? {
        leaves.first { $0.id == leafID }?.sessionID
    }

    public func leafID(ofSession sessionID: UUID) -> UUID? {
        leaves.first { $0.sessionID == sessionID }?.id
    }

    /// Replaces `leafID` with a split holding the existing leaf and a new leaf for `sessionID`.
    /// The new leaf goes after the existing one (right of, or below it).
    public func splitting(leaf leafID: UUID, axis: SplitAxis, newLeafID: UUID = UUID(), sessionID: UUID) -> PaneNode {
        switch self {
        case .leaf(let id, _) where id == leafID:
            return .split(id: UUID(), axis: axis, first: self, second: .leaf(id: newLeafID, sessionID: sessionID), fraction: 0.5)
        case .leaf:
            return self
        case .split(let id, let splitAxis, let first, let second, let fraction):
            return .split(
                id: id, axis: splitAxis,
                first: first.splitting(leaf: leafID, axis: axis, newLeafID: newLeafID, sessionID: sessionID),
                second: second.splitting(leaf: leafID, axis: axis, newLeafID: newLeafID, sessionID: sessionID),
                fraction: fraction)
        }
    }

    /// Removes a leaf; its sibling takes the parent's place. Nil when nothing is left.
    public func removing(leaf leafID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id, _):
            return id == leafID ? nil : self
        case .split(let id, let axis, let first, let second, let fraction):
            let newFirst = first.removing(leaf: leafID)
            let newSecond = second.removing(leaf: leafID)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?): return .split(id: id, axis: axis, first: a, second: b, fraction: fraction)
            }
        }
    }

    public func settingFraction(_ newFraction: Double, forSplit splitID: UUID) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let first, let second, let fraction):
            let clamped = min(max(newFraction, 0.1), 0.9)
            return .split(
                id: id, axis: axis,
                first: first.settingFraction(newFraction, forSplit: splitID),
                second: second.settingFraction(newFraction, forSplit: splitID),
                fraction: id == splitID ? clamped : fraction)
        }
    }

    /// Frame of every leaf when the tree fills `bounds` (origin top-left, y grows downward).
    public func leafFrames(in bounds: CGRect) -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]
        collectFrames(in: bounds, into: &frames)
        return frames
    }

    private func collectFrames(in bounds: CGRect, into frames: inout [UUID: CGRect]) {
        switch self {
        case .leaf(let id, _):
            frames[id] = bounds
        case .split(_, let axis, let first, let second, let fraction):
            switch axis {
            case .horizontal:
                let width = bounds.width * fraction
                first.collectFrames(in: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height), into: &frames)
                second.collectFrames(in: CGRect(x: bounds.minX + width, y: bounds.minY, width: bounds.width - width, height: bounds.height), into: &frames)
            case .vertical:
                let height = bounds.height * fraction
                first.collectFrames(in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height), into: &frames)
                second.collectFrames(in: CGRect(x: bounds.minX, y: bounds.minY + height, width: bounds.width, height: bounds.height - height), into: &frames)
            }
        }
    }

    /// The leaf reached by moving from `leafID` in `direction`, judged by layout geometry.
    /// Ties (equal distance and overlap) go to the pane nearest the origin's centre line,
    /// then the top-most / left-most one, so navigation is deterministic.
    public func neighbor(of leafID: UUID, direction: PaneDirection) -> UUID? {
        let frames = leafFrames(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        guard let origin = frames[leafID] else { return nil }
        let epsilon = 0.5
        struct Candidate { let id: UUID; let distance: CGFloat; let overlap: CGFloat; let offCentre: CGFloat; let order: CGFloat }
        var candidates: [Candidate] = []
        for (id, frame) in frames where id != leafID {
            let distance: CGFloat
            let overlap: CGFloat
            let offCentre: CGFloat
            let order: CGFloat
            switch direction {
            case .right:
                guard frame.minX >= origin.maxX - epsilon else { continue }
                distance = frame.minX - origin.maxX
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
                offCentre = abs(frame.midY - origin.midY)
                order = frame.minY
            case .left:
                guard frame.maxX <= origin.minX + epsilon else { continue }
                distance = origin.minX - frame.maxX
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
                offCentre = abs(frame.midY - origin.midY)
                order = frame.minY
            case .down:
                guard frame.minY >= origin.maxY - epsilon else { continue }
                distance = frame.minY - origin.maxY
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
                offCentre = abs(frame.midX - origin.midX)
                order = frame.minX
            case .up:
                guard frame.maxY <= origin.minY + epsilon else { continue }
                distance = origin.minY - frame.maxY
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
                offCentre = abs(frame.midX - origin.midX)
                order = frame.minX
            }
            guard overlap > epsilon else { continue }
            candidates.append(Candidate(id: id, distance: distance, overlap: overlap, offCentre: offCentre, order: order))
        }
        return candidates.min { a, b in
            if abs(a.distance - b.distance) > epsilon { return a.distance < b.distance }
            if abs(a.overlap - b.overlap) > epsilon { return a.overlap > b.overlap }
            if abs(a.offCentre - b.offCentre) > epsilon { return a.offCentre < b.offCentre }
            return a.order < b.order
        }?.id
    }
}
