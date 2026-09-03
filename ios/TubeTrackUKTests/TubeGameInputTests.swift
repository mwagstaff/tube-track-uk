import CoreGraphics
import Testing
@testable import TubeTrackUK

@Suite("Station Chase input")
struct TubeGameInputTests {
    @Test func swipeUsesATightDeadZoneThenResolvesAllEightSectors() {
        #expect(TubeGameGestureIntent.swipeDirection(
            for: CGSize(width: 1.49, height: 0)
        ) == nil)

        let samples: [(CGSize, TubeGameDirection)] = [
            (CGSize(width: 0, height: -1.5), .north),
            (CGSize(width: 1.5, height: -1.5), .northEast),
            (CGSize(width: 1.5, height: 0), .east),
            (CGSize(width: 1.5, height: 1.5), .southEast),
            (CGSize(width: 0, height: 1.5), .south),
            (CGSize(width: -1.5, height: 1.5), .southWest),
            (CGSize(width: -1.5, height: 0), .west),
            (CGSize(width: -1.5, height: -1.5), .northWest),
        ]

        for (translation, expectedDirection) in samples {
            #expect(
                TubeGameGestureIntent.swipeDirection(for: translation)
                    == expectedDirection
            )
        }
    }

    @Test func slightlyDiagonalSwipesPreferForgivingCardinalDirections() {
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: -60.1)
        ) == .north)
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: -119.9)
        ) == .north)
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: -59.9)
        ) == .northEast)
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: -120.1)
        ) == .northWest)
    }

    @Test func liveSwipeEmitsOnlySectorChangesAndDoesNotRepeatAtTouchUp() {
        var tracker = TubeGameGestureIntentTracker()

        #expect(tracker.updateSwipe(for: CGSize(width: 1.5, height: 0)) == .east)
        #expect(tracker.updateSwipe(for: CGSize(width: 30, height: 1)) == nil)
        #expect(tracker.updateSwipe(for: CGSize(width: 20, height: -20)) == .northEast)
        #expect(tracker.finishSwipe(
            translation: CGSize(width: 20, height: -20)
        ) == nil)

        #expect(tracker.activeSwipeDirection == nil)
        #expect(tracker.updateSwipe(for: CGSize(width: 1.5, height: -1.5)) == .northEast)
    }

    @Test func cancelledGestureCannotPoisonTheNextGesture() {
        var tracker = TubeGameGestureIntentTracker()

        #expect(tracker.updateSwipe(for: translation(at: 0)) == .east)
        tracker.cancel()
        #expect(tracker.activeSwipeDirection == nil)
        #expect(tracker.updateSwipe(for: translation(at: 0)) == .east)
    }

    @Test func hysteresisSuppressesChatterAroundASectorBoundary() {
        var tracker = TubeGameGestureIntentTracker()

        #expect(tracker.updateSwipe(for: translation(at: 0)) == .east)
        for angle in [29.9, 30.1, 33, 34.9, 31, 34] {
            #expect(tracker.updateSwipe(for: translation(at: angle)) == nil)
        }
        #expect(tracker.activeSwipeDirection == .east)
        #expect(tracker.updateSwipe(for: translation(at: 35.1)) == .southEast)

        for angle in [35, 30, 25.1] {
            #expect(tracker.updateSwipe(for: translation(at: angle)) == nil)
        }
        #expect(tracker.activeSwipeDirection == .southEast)
        #expect(tracker.updateSwipe(for: translation(at: 24.9)) == .east)
    }

    @Test func biasedBoundaryAndAngleWrapRemainDeterministic() {
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: 29.999)
        ) == .east)
        #expect(TubeGameGestureIntent.swipeDirection(
            for: translation(at: 30.001)
        ) == .southEast)

        var tracker = TubeGameGestureIntentTracker()
        #expect(tracker.updateSwipe(for: translation(at: 180)) == .west)
        #expect(tracker.updateSwipe(for: translation(at: -179.9)) == nil)
        #expect(tracker.updateSwipe(for: translation(at: -145.1)) == nil)
        #expect(tracker.updateSwipe(for: translation(at: -144.9)) == .northWest)
    }

    @Test func finishEmitsOneFastFlickWhenNoLiveEventArrived() {
        var tracker = TubeGameGestureIntentTracker()
        let direction = tracker.finishSwipe(
            translation: CGSize(width: 1.5, height: 0)
        )

        #expect(direction == .east)
        #expect(tracker.activeSwipeDirection == nil)
    }

    private func translation(
        at degrees: CGFloat,
        distance: CGFloat = 40
    ) -> CGSize {
        let radians = degrees * .pi / 180
        return CGSize(
            width: cos(radians) * distance,
            height: sin(radians) * distance
        )
    }
}
