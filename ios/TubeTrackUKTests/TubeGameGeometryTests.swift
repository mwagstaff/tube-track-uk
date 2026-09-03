import CoreGraphics
import Testing
@testable import TubeTrackUK

struct TubeGameGeometryTests {
    @Test func playerIntentResolvesAllEightScreenSpaceSectors() {
        let directions: [(CGFloat, TubeGameDirection)] = [
            (0, .east),
            (45, .southEast),
            (90, .south),
            (135, .southWest),
            (180, .west),
            (225, .northWest),
            (270, .north),
            (315, .northEast),
        ]

        for (degrees, expected) in directions {
            let radians = degrees * .pi / 180
            #expect(TubeGameDirection(screenAngleRadians: radians) == expected)
            #expect(TubeGameDirection(vector: CGVector(
                dx: cos(radians) * 100,
                dy: sin(radians) * 100
            )) == expected)
        }

        #expect(TubeGameDirection(screenAngleRadians: 22.49 * .pi / 180) == .east)
        #expect(TubeGameDirection(screenAngleRadians: 22.51 * .pi / 180) == .southEast)
        #expect(TubeGameDirection(vector: .zero) == nil)
        #expect(TubeGameDirection(vector: CGVector(dx: CGFloat.infinity, dy: 0)) == nil)
    }

    @Test func reverseDirectionOrdersTranslatedPathFromLogicalStartToEnd() throws {
        let commands: [BeckMapPathCommand] = [
            .move(to: BeckMapPoint(x: 0, y: 0)),
            .line(to: BeckMapPoint(x: 10, y: 0)),
        ]

        let geometry = TubeGameGeometryBuilder.build(
            commands: commands,
            translation: BeckMapTranslation(x: 3, y: 4),
            direction: .reverse
        )

        #expect(geometry.points == [CGPoint(x: 13, y: 4), CGPoint(x: 3, y: 4)])
        #expect(try #require(geometry.point(atProgress: 0.25)).x == 10.5)
        #expect(try #require(geometry.startTangent).dx == -1)
        #expect(try #require(geometry.startTangent).dy == 0)
        #expect(try #require(geometry.endTangent).dx == -1)
        #expect(try #require(geometry.endTangent).dy == 0)
    }

    @Test func cubicSamplingPreservesEndpointsAndArcMidpoint() throws {
        let geometry = TubeGameGeometryBuilder.build(commands: [
            .move(to: BeckMapPoint(x: 0, y: 0)),
            .cubic(
                control1: BeckMapPoint(x: 0, y: 10),
                control2: BeckMapPoint(x: 10, y: 10),
                to: BeckMapPoint(x: 10, y: 0)
            ),
        ])

        #expect(geometry.points.count > 2)
        #expect(geometry.points.first == CGPoint(x: 0, y: 0))
        #expect(geometry.points.last == CGPoint(x: 10, y: 0))
        let midpoint = try #require(geometry.point(atProgress: 0.5))
        #expect(abs(midpoint.x - 5) < 0.001)
        #expect(abs(midpoint.y - 7.5) < 0.001)
    }

    @Test func cubicSamplingRetainsCollinearBacktrackingLength() {
        let geometry = TubeGameGeometryBuilder.build(commands: [
            .move(to: BeckMapPoint(x: 0, y: 0)),
            .cubic(
                control1: BeckMapPoint(x: 10, y: 0),
                control2: BeckMapPoint(x: -10, y: 0),
                to: BeckMapPoint(x: 0, y: 0)
            ),
        ])

        #expect(geometry.points.count > 2)
        #expect(geometry.totalLength > 10)
        #expect(geometry.points.first == CGPoint(x: 0, y: 0))
        #expect(geometry.points.last == CGPoint(x: 0, y: 0))
    }

    @Test func lengthInterpolationAndTangentsFollowPolyline() throws {
        let geometry = TubeGameGeometryBuilder.build(commands: [
            .move(to: BeckMapPoint(x: 0, y: 0)),
            .line(to: BeckMapPoint(x: 3, y: 4)),
            .line(to: BeckMapPoint(x: 3, y: 8)),
        ])

        #expect(geometry.cumulativeLengths == [0, 5, 9])
        #expect(geometry.totalLength == 9)
        #expect(geometry.point(atDistance: -1) == CGPoint(x: 0, y: 0))
        #expect(geometry.point(atDistance: 100) == CGPoint(x: 3, y: 8))

        let halfwayAlongFirstEdge = try #require(geometry.point(atDistance: 2.5))
        #expect(abs(halfwayAlongFirstEdge.x - 1.5) < 0.001)
        #expect(abs(halfwayAlongFirstEdge.y - 2) < 0.001)

        let startTangent = try #require(geometry.startTangent)
        #expect(abs(startTangent.dx - 0.6) < 0.001)
        #expect(abs(startTangent.dy - 0.8) < 0.001)
        #expect(geometry.endTangent == CGVector(dx: 0, dy: 1))
    }

    @Test func closeCommandAddsClosingEdge() {
        let geometry = TubeGameGeometryBuilder.build(commands: [
            .move(to: BeckMapPoint(x: 0, y: 0)),
            .line(to: BeckMapPoint(x: 3, y: 0)),
            .line(to: BeckMapPoint(x: 3, y: 4)),
            .close,
        ])

        #expect(geometry.points == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 3, y: 0),
            CGPoint(x: 3, y: 4),
            CGPoint(x: 0, y: 0),
        ])
        #expect(geometry.totalLength == 12)
    }

    @Test func emptyAndDegenerateCommandsRemainSafe() throws {
        let empty = TubeGameGeometryBuilder.build(commands: [])
        #expect(empty.points.isEmpty)
        #expect(empty.cumulativeLengths.isEmpty)
        #expect(empty.totalLength == 0)
        #expect(empty.startTangent == nil)
        #expect(empty.endTangent == nil)
        #expect(empty.point(atProgress: 0.5) == nil)
        #expect(empty.point(atDistance: 1) == nil)

        let repeatedPoint = BeckMapPoint(x: 2, y: 3)
        let degenerate = TubeGameGeometryBuilder.build(commands: [
            .move(to: repeatedPoint),
            .line(to: repeatedPoint),
            .cubic(control1: repeatedPoint, control2: repeatedPoint, to: repeatedPoint),
            .close,
        ])
        #expect(degenerate.points == [CGPoint(x: 2, y: 3)])
        #expect(degenerate.cumulativeLengths == [0])
        #expect(degenerate.totalLength == 0)
        #expect(degenerate.startTangent == nil)
        #expect(degenerate.endTangent == nil)
        #expect(degenerate.point(atProgress: .nan) == CGPoint(x: 2, y: 3))
        #expect(degenerate.point(atDistance: .infinity) == CGPoint(x: 2, y: 3))
    }
}
