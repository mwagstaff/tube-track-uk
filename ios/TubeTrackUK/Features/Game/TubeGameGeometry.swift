import CoreGraphics
import Foundation

extension TubeGameDirection {
    /// Resolves a screen-space vector into one of eight equal 45-degree sectors.
    /// Positive y points down, matching SwiftUI gesture coordinates.
    init?(vector: CGVector) {
        guard vector.dx.isFinite, vector.dy.isFinite,
              hypot(vector.dx, vector.dy) > 0.000_001 else { return nil }
        self.init(screenAngleRadians: atan2(vector.dy, vector.dx))
    }

    /// Resolves a screen-space angle where zero points east and positive values
    /// rotate clockwise. Sector boundaries sit halfway between compass points.
    init?(screenAngleRadians angle: CGFloat) {
        guard angle.isFinite else { return nil }
        let fullTurn = CGFloat.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: fullTurn)
        if normalized < 0 { normalized += fullTurn }
        let sectorWidth = CGFloat.pi / 4
        let sector = Int(floor((normalized + sectorWidth / 2) / sectorWidth)) % 8
        switch sector {
        case 0: self = .east
        case 1: self = .southEast
        case 2: self = .south
        case 3: self = .southWest
        case 4: self = .west
        case 5: self = .northWest
        case 6: self = .north
        default: self = .northEast
        }
    }
}

/// A sampled Beck path ordered in the segment's logical `from` to `to` direction.
///
/// Distances are measured along the sampled polyline. Tangents are normalized and
/// point in the logical direction of travel, including at the end of the path.
struct TubeGamePathGeometry: Sendable {
    let points: [CGPoint]
    let cumulativeLengths: [CGFloat]
    let totalLength: CGFloat
    let startTangent: CGVector?
    let endTangent: CGVector?

    init(points: [CGPoint]) {
        let points = Self.removingInvalidAndDuplicatePoints(from: points)
        self.points = points

        guard !points.isEmpty else {
            cumulativeLengths = []
            totalLength = 0
            startTangent = nil
            endTangent = nil
            return
        }

        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count)
        for (start, end) in zip(points, points.dropFirst()) {
            lengths.append(lengths[lengths.endIndex - 1] + Self.distance(from: start, to: end))
        }
        cumulativeLengths = lengths
        totalLength = lengths.last ?? 0
        startTangent = points.count > 1
            ? Self.unitVector(from: points[0], to: points[1])
            : nil
        endTangent = points.count > 1
            ? Self.unitVector(from: points[points.count - 2], to: points[points.count - 1])
            : nil
    }

    func point(atProgress progress: Double) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard !progress.isNaN else { return first }
        if progress <= 0 { return first }
        if progress >= 1 { return points.last }
        return point(atDistance: totalLength * CGFloat(progress))
    }

    func point(atDistance distance: CGFloat) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1, totalLength > 0 else { return first }
        guard !distance.isNaN else { return first }
        if distance <= 0 { return first }
        if distance >= totalLength { return points.last }

        var lowerBound = 1
        var upperBound = cumulativeLengths.count - 1
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if cumulativeLengths[midpoint] < distance {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let endIndex = lowerBound
        let startIndex = endIndex - 1
        let edgeLength = cumulativeLengths[endIndex] - cumulativeLengths[startIndex]
        guard edgeLength > 0 else { return points[endIndex] }

        let fraction = (distance - cumulativeLengths[startIndex]) / edgeLength
        let start = points[startIndex]
        let end = points[endIndex]
        return CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }

    private static func removingInvalidAndDuplicatePoints(from points: [CGPoint]) -> [CGPoint] {
        let duplicateToleranceSquared = CGFloat(0.000_001 * 0.000_001)
        return points.reduce(into: []) { result, point in
            guard point.x.isFinite, point.y.isFinite else { return }
            guard let previous = result.last else {
                result.append(point)
                return
            }
            let deltaX = point.x - previous.x
            let deltaY = point.y - previous.y
            guard deltaX * deltaX + deltaY * deltaY > duplicateToleranceSquared else { return }
            result.append(point)
        }
    }

    private static func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private static func unitVector(from start: CGPoint, to end: CGPoint) -> CGVector? {
        let length = distance(from: start, to: end)
        guard length > 0 else { return nil }
        return CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
    }
}

enum TubeGameGeometryBuilder {
    private static let cubicFlatnessTolerance: CGFloat = 0.5
    private static let maximumSubdivisionDepth = 12

    static func build(
        commands: [BeckMapPathCommand],
        translation: BeckMapTranslation = .zero,
        direction: BeckMapPathDirection = .forward
    ) -> TubeGamePathGeometry {
        var points: [CGPoint] = []
        var currentPoint: CGPoint?
        var subpathStart: CGPoint?

        for command in commands {
            switch command {
            case let .move(to):
                let destination = translated(to, by: translation)
                points.append(destination)
                currentPoint = destination
                subpathStart = destination

            case let .line(to):
                let destination = translated(to, by: translation)
                points.append(destination)
                currentPoint = destination

            case let .cubic(control1, control2, to):
                let destination = translated(to, by: translation)
                guard let start = currentPoint else {
                    points.append(destination)
                    currentPoint = destination
                    subpathStart = destination
                    continue
                }
                appendCubic(
                    from: start,
                    control1: translated(control1, by: translation),
                    control2: translated(control2, by: translation),
                    to: destination,
                    depth: 0,
                    points: &points
                )
                currentPoint = destination

            case .close:
                guard let subpathStart else { continue }
                points.append(subpathStart)
                currentPoint = subpathStart
            }
        }

        if direction == .reverse {
            points.reverse()
        }
        return TubeGamePathGeometry(points: points)
    }

    private static func translated(
        _ point: BeckMapPoint,
        by translation: BeckMapTranslation
    ) -> CGPoint {
        CGPoint(x: point.x + translation.x, y: point.y + translation.y)
    }

    private static func appendCubic(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        depth: Int,
        points: inout [CGPoint]
    ) {
        guard depth < maximumSubdivisionDepth,
              !isFlatEnough(
                  from: start,
                  control1: control1,
                  control2: control2,
                  to: end
              ) else {
            points.append(end)
            return
        }

        let startControlMidpoint = midpoint(start, control1)
        let controlMidpoint = midpoint(control1, control2)
        let controlEndMidpoint = midpoint(control2, end)
        let leftControl = midpoint(startControlMidpoint, controlMidpoint)
        let rightControl = midpoint(controlMidpoint, controlEndMidpoint)
        let curveMidpoint = midpoint(leftControl, rightControl)

        appendCubic(
            from: start,
            control1: startControlMidpoint,
            control2: leftControl,
            to: curveMidpoint,
            depth: depth + 1,
            points: &points
        )
        appendCubic(
            from: curveMidpoint,
            control1: rightControl,
            control2: controlEndMidpoint,
            to: end,
            depth: depth + 1,
            points: &points
        )
    }

    private static func isFlatEnough(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint
    ) -> Bool {
        let maximumControlDistance = max(
            distanceFromLine(control1, lineStart: start, lineEnd: end),
            distanceFromLine(control2, lineStart: start, lineEnd: end)
        )
        let chordLength = hypot(end.x - start.x, end.y - start.y)
        let controlPolygonLength = hypot(control1.x - start.x, control1.y - start.y)
            + hypot(control2.x - control1.x, control2.y - control1.y)
            + hypot(end.x - control2.x, end.y - control2.y)
        return maximumControlDistance <= cubicFlatnessTolerance
            && controlPolygonLength - chordLength <= cubicFlatnessTolerance
    }

    private static func distanceFromLine(
        _ point: CGPoint,
        lineStart: CGPoint,
        lineEnd: CGPoint
    ) -> CGFloat {
        let deltaX = lineEnd.x - lineStart.x
        let deltaY = lineEnd.y - lineStart.y
        let lineLength = hypot(deltaX, deltaY)
        guard lineLength > 0 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        return abs(
            deltaY * point.x
                - deltaX * point.y
                + lineEnd.x * lineStart.y
                - lineEnd.y * lineStart.x
        ) / lineLength
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}
