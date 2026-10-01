import QuartzCore
import SwiftUI
import Testing
@testable import TubeTrackUK

@MainActor
struct MapScrollContinuityTests {
    @Test func momentumUsesElapsedTimeAcrossMissedAndVariableFrames() {
        func coast(at times: [Double]) -> (CGSize, CGPoint, Double) {
            var clock = BeckMapMomentumClock(startedAt: 100)
            var velocity = CGPoint(x: 800, y: -300)
            var distance = CGSize.zero
            for time in times {
                let duration = clock.advance(to: 100 + time)
                let next = BeckMapMomentumPolicy.attenuatedVelocity(velocity, over: duration)
                let delta = BeckMapMomentumPolicy.translation(from: velocity, to: next, over: duration)
                distance.width += delta.width
                distance.height += delta.height
                velocity = next
            }
            return (distance, velocity, clock.elapsed)
        }
        let regular = coast(at: (1...120).map { Double($0) / 120 })
        // Includes a 250 ms stall, repeated timestamp and refresh-rate changes.
        let irregular = coast(at: [0.008, 0.016, 0.033, 0.283, 0.3, 0.3, 0.6, 1])
        #expect(abs(regular.0.width - irregular.0.width) < 0.000_001)
        #expect(abs(regular.0.height - irregular.0.height) < 0.000_001)
        #expect(abs(regular.1.x - irregular.1.x) < 0.000_001)
        #expect(abs(regular.2 - irregular.2) < 0.000_001)
    }

    @Test func momentumClockRejectsInvalidTimeAndBoundsLongSuspensions() {
        var clock = BeckMapMomentumClock(startedAt: 10)
        #expect(clock.advance(to: .nan) == 0)
        #expect(clock.advance(to: 9) == 0)
        #expect(abs(clock.advance(to: 10.1) - 0.1) < 0.000_001)
        _ = clock.advance(to: 100)
        #expect(clock.elapsed == BeckMapMomentumPolicy.maximumDuration)
        #expect(clock.advance(to: 101) == 0)
    }

    @Test func panningProjectsTheSameLabelWithoutRelayoutOrPositionJumps() throws {
        let viewport = BeckMapLabelLayoutViewport.network(
            bounds: CGRect(x: -200, y: -100, width: 4_000, height: 3_000),
            scale: 0.5, typeScale: 1.6
        )
        let placement = StationLabelPlacement(
            labelID: "station", position: CGPoint(x: viewport.offset.width + 100, y: viewport.offset.height + 200),
            alignment: .trailing, rotation: CGAffineTransform(rotationAngle: .pi / 4),
            backgroundBounds: CGRect(x: -60, y: -10, width: 60, height: 20),
            collisionFrame: CGRect(x: viewport.offset.width + 50, y: viewport.offset.height + 150, width: 70, height: 70)
        )
        for x in stride(from: CGFloat(-40), through: 600, by: 4) {
            let offset = CGSize(width: x, height: 20)
            let projected = try #require(viewport.project([placement], into: CGSize(width: 900, height: 700), at: offset).first)
            #expect(abs(projected.position.x - (100 + x)) < 0.000_001)
            #expect(abs(projected.position.y - 220) < 0.000_001)
            #expect(projected.rotation == placement.rotation)
            #expect(projected.backgroundBounds == placement.backgroundBounds)
            #expect(projected.alignment == placement.alignment)
        }
        #expect(viewport.project([placement], into: CGSize(width: 900, height: 700),
                                 at: CGSize(width: -1_000, height: 0)).isEmpty)
        // A partially visible label is retained and clipped by the Canvas.
        #expect(!viewport.project([placement], into: CGSize(width: 900, height: 700),
                                  at: CGSize(width: -100, height: 0)).isEmpty)
    }
}
