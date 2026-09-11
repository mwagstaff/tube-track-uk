import CoreGraphics
import Testing
import UIKit
@testable import TubeTrackUK

@MainActor
struct BeckMapGestureSurfaceTests {
    @Test func panOnsetAndChangesReachTheCameraBeforeTheNextDisplayRefresh() {
        let recorder = GestureRecorder()
        recorder.camera.update(scale: 0.6, offset: CGSize(width: 100, height: 200))
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }

        coordinator.handlePan(state: .began, translation: CGSize(width: 12, height: -5))

        #expect(recorder.camera.offset == CGSize(width: 112, height: 195))
        #expect(recorder.panPhases.first == "began")
        #expect(recorder.panPhases.last == "changed")
        #expect(recorder.cameraOffsetsAtInteraction.first == CGSize(width: 112, height: 195))
        #expect(!coordinator.isDisplayLinkActive)

        coordinator.handlePan(state: .changed, translation: CGSize(width: 30, height: 20))
        #expect(recorder.camera.offset == CGSize(width: 130, height: 220))
        #expect(!coordinator.isDisplayLinkActive)

        // Recognizer translations are cumulative, so repeating a value cannot
        // add the same distance twice or wait for a run-loop/display-link tick.
        coordinator.handlePan(state: .changed, translation: CGSize(width: 30, height: 20))
        #expect(recorder.camera.offset == CGSize(width: 130, height: 220))
        coordinator.handlePan(state: .ended, translation: CGSize(width: 45, height: 25))
        #expect(recorder.camera.offset == CGSize(width: 145, height: 225))
        #expect(recorder.interactions == [true, false])
        #expect(recorder.panPhases.filter { $0 == "ended" }.count == 1)
    }

    @Test func pinchChangesReachTheCameraSynchronouslyWithoutATrackingDisplayLink() {
        let recorder = GestureRecorder()
        recorder.camera.update(scale: 0.5, offset: CGSize(width: -100, height: -200))
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        let initialLocation = CGPoint(x: 200, y: 300)

        coordinator.handlePinch(state: .began, magnification: 1.2, location: initialLocation)
        #expect(recorder.camera.scale == 0.6)
        #expect(recorder.camera.offset == CGSize(width: -160, height: -300))
        #expect(!coordinator.isDisplayLinkActive)
        coordinator.handlePinch(state: .changed, magnification: 1.5, location: CGPoint(x: 210, y: 320))

        #expect(recorder.camera.scale == 0.75)
        #expect(recorder.camera.offset == CGSize(width: -240, height: -430))
        #expect(recorder.pinchPhases.last == "changed")
        #expect(!coordinator.isDisplayLinkActive)

        coordinator.handlePinch(state: .ended, magnification: 1.6, location: CGPoint(x: 220, y: 330))
        #expect(abs(recorder.camera.scale - 0.8) < 0.000_001)
        #expect(recorder.camera.offset == CGSize(width: -260, height: -470))
        #expect(recorder.interactions == [true, false])
    }

    @Test func draggingACoastingMapDoesNotFinishAndRestartTheInteraction() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        startCoasting(coordinator)
        let coastingOffset = recorder.camera.offset
        #expect(coordinator.isDecelerating)
        #expect(coordinator.isDisplayLinkActive)

        coordinator.handlePan(state: .began, translation: CGSize(width: 9, height: -4))

        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)
        #expect(recorder.camera.offset == CGSize(width: coastingOffset.width + 9, height: coastingOffset.height - 4))
        #expect(!recorder.panPhases.contains("ended"))
        #expect(recorder.interactions == [true])

        coordinator.handlePan(state: .ended, translation: CGSize(width: 20, height: 5))
        #expect(recorder.interactions == [true, false])
        #expect(recorder.panPhases.filter { $0 == "ended" }.count == 1)
    }

    @Test func pinchingACoastingMapKeepsOneContinuousInteraction() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        startCoasting(coordinator)

        coordinator.handlePinch(state: .began, magnification: 1, location: CGPoint(x: 180, y: 280))

        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)
        #expect(!recorder.panPhases.contains("ended"))
        #expect(recorder.interactions == [true])
        coordinator.handlePinch(state: .changed, magnification: 1.2, location: CGPoint(x: 180, y: 280))
        #expect(abs(recorder.camera.scale - 0.42) < 0.000_001)
        coordinator.handlePinch(state: .ended, magnification: 1.2, location: CGPoint(x: 180, y: 280))
        #expect(recorder.interactions == [true, false])
        #expect(recorder.pinchPhases.filter { $0 == "ended" }.count == 1)
    }

    @Test func touchingACoastingMapStopsItBeforeDragRecognitionAndEndsOnceOnRelease() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        startCoasting(coordinator)
        let touchedOffset = recorder.camera.offset

        coordinator.touchBegan()

        #expect(recorder.touchDownCount == 1)
        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)
        #expect(recorder.camera.offset == touchedOffset)
        #expect(recorder.panPhases.last == "interrupted")
        #expect(!recorder.panPhases.contains("ended"))
        #expect(recorder.interactions == [true])

        coordinator.touchesEnded()
        coordinator.touchesEnded()
        #expect(recorder.panPhases.filter { $0 == "ended" }.count == 1)
        #expect(recorder.interactions == [true, false])
    }

    @Test func touchDownThenDragPreservesTheCoastingCameraWithoutAnIntermediateEnd() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        startCoasting(coordinator)
        let touchedOffset = recorder.camera.offset
        coordinator.touchBegan()
        coordinator.handlePan(state: .began, translation: CGSize(width: 6, height: 3))
        coordinator.handlePan(state: .changed, translation: CGSize(width: 16, height: 13))

        #expect(recorder.camera.offset == CGSize(width: touchedOffset.width + 16, height: touchedOffset.height + 13))
        #expect(recorder.interactions == [true])
        #expect(!recorder.panPhases.contains("ended"))
        #expect(!coordinator.isDisplayLinkActive)
    }

    @Test func catchingAProgrammaticCameraAnimationPublishesTheFinalViewportOnTouchRelease() {
        let recorder = GestureRecorder()
        let animator = BeckMapCameraAnimator()
        animator.animate(duration: 10, easing: { $0 }, update: { _ in }, completion: {})
        let coordinator = recorder.makeCoordinator(onTouchDown: {
            let wasAnimating = animator.isAnimating
            animator.cancel()
            return wasAnimating
        })
        defer {
            coordinator.stopAllMotion()
            animator.cancel()
        }

        coordinator.touchBegan()

        #expect(!animator.isAnimating)
        #expect(recorder.touchDownCount == 1)
        #expect(recorder.panPhases == ["interrupted"])
        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)

        coordinator.touchesEnded()
        coordinator.touchesEnded()
        #expect(recorder.panPhases == ["interrupted", "ended"])
        #expect(!coordinator.isDisplayLinkActive)
    }

    @Test func draggingAfterCatchingAProgrammaticAnimationAvoidsAnIntermediateViewportPublication() {
        let recorder = GestureRecorder()
        recorder.camera.update(scale: 0.7, offset: CGSize(width: -120, height: 90))
        let animator = BeckMapCameraAnimator()
        animator.animate(duration: 10, easing: { $0 }, update: { _ in }, completion: {})
        let coordinator = recorder.makeCoordinator(onTouchDown: {
            let wasAnimating = animator.isAnimating
            animator.cancel()
            return wasAnimating
        })
        defer {
            coordinator.stopAllMotion()
            animator.cancel()
        }

        coordinator.touchBegan()
        coordinator.handlePan(state: .began, translation: CGSize(width: 6, height: 3))
        coordinator.handlePan(state: .changed, translation: CGSize(width: 16, height: 13))

        #expect(!animator.isAnimating)
        #expect(recorder.camera.offset == CGSize(width: -104, height: 103))
        #expect(recorder.panPhases.first == "interrupted")
        #expect(!recorder.panPhases.contains("ended"))
        #expect(recorder.interactions == [true])
        #expect(!coordinator.isDisplayLinkActive)

        coordinator.handlePan(state: .ended, translation: CGSize(width: 16, height: 13))
        coordinator.touchesEnded()
        #expect(recorder.panPhases.filter { $0 == "ended" }.count == 1)
        #expect(recorder.interactions == [true, false])
    }

    @Test func rawTouchReleaseDoesNotCancelNewlyStartedMomentum() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        coordinator.touchBegan()
        startCoasting(coordinator)

        // UIKit can deliver the recognizer's ended event before the underlying
        // view receives touchesEnded for the same physical release.
        coordinator.touchesEnded()

        #expect(coordinator.isDecelerating)
        #expect(coordinator.isDisplayLinkActive)
        #expect(!recorder.panPhases.contains("ended"))
        #expect(recorder.interactions == [true])
    }

    @Test func tappingAPausedCoastEndsOnceRegardlessOfUIKitCallbackOrder() {
        for tapArrivesFirst in [false, true] {
            let recorder = GestureRecorder()
            let coordinator = recorder.makeCoordinator()
            defer { coordinator.stopAllMotion() }
            startCoasting(coordinator)
            coordinator.touchBegan()
            let location = CGPoint(x: 125, y: 260)

            if tapArrivesFirst {
                coordinator.handleTap(at: location)
                coordinator.touchesEnded()
            } else {
                coordinator.touchesEnded()
                coordinator.handleTap(at: location)
            }

            #expect(recorder.panPhases.filter { $0 == "ended" }.count == 1)
            #expect(recorder.interactions == [true, false])
            #expect(recorder.taps == [location])
            #expect(!coordinator.isDisplayLinkActive)
        }
    }

    @Test func anOrdinaryTapDoesNotStartOrFinishAPan() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        let tapLocation = CGPoint(x: 125, y: 260)

        coordinator.touchBegan()
        coordinator.touchesEnded()
        coordinator.handleTap(at: tapLocation)

        #expect(recorder.touchDownCount == 1)
        #expect(recorder.taps == [tapLocation])
        #expect(recorder.panPhases.isEmpty)
        #expect(recorder.pinchPhases.isEmpty)
        #expect(recorder.interactions.isEmpty)
        #expect(!coordinator.isDisplayLinkActive)
    }

    @Test func stalePanCallbacksCannotFinishAnActivePinch() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        coordinator.handlePan(state: .began, translation: CGSize(width: 8, height: 4))
        coordinator.handlePinch(state: .began, magnification: 1, location: CGPoint(x: 150, y: 250))
        let panEventCount = recorder.panPhases.count
        let cameraBeforeStaleEvents = recorder.camera.offset

        for state in [UIGestureRecognizer.State.changed, .cancelled, .ended] {
            coordinator.handlePan(state: state, translation: CGSize(width: 500, height: 500), velocity: CGPoint(x: 3_000, y: 0))
        }

        #expect(recorder.panPhases.count == panEventCount)
        #expect(recorder.camera.offset == cameraBeforeStaleEvents)
        #expect(recorder.interactions == [true])
        #expect(!coordinator.isDisplayLinkActive)
        coordinator.handlePinch(state: .changed, magnification: 1.3, location: CGPoint(x: 150, y: 250))
        #expect(abs(recorder.camera.scale - 0.455) < 0.000_001)
    }

    @Test func latePinchCallbacksAreIgnoredAfterThePinchEnds() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        defer { coordinator.stopAllMotion() }
        let location = CGPoint(x: 150, y: 250)
        coordinator.handlePinch(state: .began, magnification: 1, location: location)
        coordinator.handlePinch(state: .ended, magnification: 1.2, location: location)
        let eventCount = recorder.pinchPhases.count
        let finalScale = recorder.camera.scale
        let finalOffset = recorder.camera.offset

        for state in [UIGestureRecognizer.State.changed, .cancelled, .ended] {
            coordinator.handlePinch(state: state, magnification: 2, location: .zero)
        }

        #expect(recorder.pinchPhases.count == eventCount)
        #expect(recorder.camera.scale == finalScale)
        #expect(recorder.camera.offset == finalOffset)
        #expect(recorder.interactions == [true, false])
    }

    @Test func reducedMotionFinishesTheDragWithoutStartingMomentum() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator(allowsMomentum: false)
        defer { coordinator.stopAllMotion() }
        startCoasting(coordinator)

        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)
        #expect(!recorder.panPhases.contains("decelerating"))
        #expect(recorder.panPhases.last == "ended")
        #expect(recorder.interactions == [true, false])
    }

    @Test func dismantlingTheSurfaceStopsMomentumAndInvalidatesItsDisplayLink() {
        let recorder = GestureRecorder()
        let coordinator = recorder.makeCoordinator()
        startCoasting(coordinator)
        #expect(coordinator.isDisplayLinkActive)

        coordinator.stopAllMotion()
        coordinator.stopAllMotion()

        #expect(!coordinator.isDecelerating)
        #expect(!coordinator.isDisplayLinkActive)
        #expect(recorder.interactions == [true, false])
    }

    private func startCoasting(_ coordinator: BeckMapGestureSurface.Coordinator) {
        coordinator.handlePan(state: .began, translation: CGSize(width: 8, height: 4))
        coordinator.handlePan(
            state: .ended,
            translation: CGSize(width: 80, height: 40),
            velocity: CGPoint(x: 2_000, y: 500)
        )
    }
}

@MainActor
private final class GestureRecorder {
    let camera = BeckMapLayerCamera()
    var panPhases: [String] = []
    var pinchPhases: [String] = []
    var interactions: [Bool] = []
    var cameraOffsetsAtInteraction: [CGSize] = []
    var touchDownCount = 0
    var taps: [CGPoint] = []
    private var panStartOffset: CGSize?
    private var pinchStartScale: CGFloat?
    private var pinchMapPoint: CGPoint?

    func makeCoordinator(
        allowsMomentum: Bool = true,
        onTouchDown: @escaping () -> Bool = { false }
    ) -> BeckMapGestureSurface.Coordinator {
        BeckMapGestureSurface.Coordinator(parent: BeckMapGestureSurface(
            allowsMomentum: allowsMomentum,
            onTouchDown: {
                self.touchDownCount += 1
                return onTouchDown()
            },
            onInteractionChange: {
                self.interactions.append($0)
                self.cameraOffsetsAtInteraction.append(self.camera.offset)
            },
            onPan: { translation, phase in self.handlePan(translation, phase: phase) },
            onPinch: { magnification, location, phase in
                self.handlePinch(magnification, location: location, phase: phase)
            },
            onTap: { self.taps.append($0) }
        ))
    }

    private func handlePan(_ translation: CGSize, phase: BeckMapGesturePhase) {
        panPhases.append(name(of: phase))
        switch phase {
        case .began:
            panStartOffset = camera.offset
        case .changed:
            let start = panStartOffset ?? camera.offset
            camera.update(scale: camera.scale, offset: CGSize(
                width: start.width + translation.width,
                height: start.height + translation.height
            ))
        case .decelerating:
            camera.update(scale: camera.scale, offset: CGSize(
                width: camera.offset.width + translation.width,
                height: camera.offset.height + translation.height
            ))
        case .interrupted, .ended:
            panStartOffset = nil
        }
    }

    private func handlePinch(_ magnification: CGFloat, location: CGPoint, phase: BeckMapGesturePhase) {
        pinchPhases.append(name(of: phase))
        switch phase {
        case .began:
            pinchStartScale = camera.scale
            pinchMapPoint = CGPoint(
                x: (location.x - camera.offset.width) / camera.scale,
                y: (location.y - camera.offset.height) / camera.scale
            )
        case .changed:
            guard let startScale = pinchStartScale, let mapPoint = pinchMapPoint else { return }
            let scale = startScale * magnification
            camera.update(scale: scale, offset: CGSize(
                width: location.x - mapPoint.x * scale,
                height: location.y - mapPoint.y * scale
            ))
        case .interrupted, .ended:
            pinchStartScale = nil
            pinchMapPoint = nil
        case .decelerating:
            break
        }
    }

    private func name(of phase: BeckMapGesturePhase) -> String {
        switch phase {
        case .began: "began"
        case .changed: "changed"
        case .decelerating: "decelerating"
        case .interrupted: "interrupted"
        case .ended: "ended"
        }
    }
}
