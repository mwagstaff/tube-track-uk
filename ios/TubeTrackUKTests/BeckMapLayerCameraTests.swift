import CoreGraphics
import Observation
import Synchronization
import Testing
import UIKit
@testable import TubeTrackUK

struct BeckMapLayerCameraTests {
    @Test func cachedArtworkStaysAlignedWithTheLiveCameraDuringPanAndPinch() {
        let renderScale: CGFloat = 0.35
        let renderOffset = CGSize(width: -470, height: 125)
        let overscan: CGFloat = 320
        let mapPoints = [
            CGPoint.zero,
            CGPoint(x: 250, y: 1_750),
            CGPoint(x: 4_200, y: 3_150),
        ]

        for cameraScale: CGFloat in [0.1, 0.35, 0.7, 1.65, 3.8] {
            for cameraOffset in [
                CGSize(width: -800, height: 600),
                renderOffset,
                CGSize(width: 240, height: -950),
            ] {
                let transform = BeckMapLayerTransform.transform(
                    cameraScale: cameraScale,
                    cameraOffset: cameraOffset,
                    renderScale: renderScale,
                    renderOffset: renderOffset,
                    overscan: overscan
                )

                for mapPoint in mapPoints {
                    let cachedPoint = CGPoint(
                        x: mapPoint.x * renderScale + renderOffset.width + overscan,
                        y: mapPoint.y * renderScale + renderOffset.height + overscan
                    )
                    let displayedPoint = cachedPoint.applying(transform)
                    #expect(abs(displayedPoint.x - (mapPoint.x * cameraScale + cameraOffset.width)) < 0.000_001)
                    #expect(abs(displayedPoint.y - (mapPoint.y * cameraScale + cameraOffset.height)) < 0.000_001)
                }
            }
        }
    }

    @Test func refreshingCachedArtworkDoesNotMoveStationOrTrainAnchors() {
        let cameraScale: CGFloat = 0.62
        let cameraOffset = CGSize(width: -570, height: -340)
        let overscan: CGFloat = 320
        let oldRenderScale: CGFloat = 0.35
        let oldRenderOffset = CGSize(width: -420, height: 100)
        let mapPoint = CGPoint(x: 1_450, y: 975)

        let previousTransform = BeckMapLayerTransform.transform(
            cameraScale: cameraScale,
            cameraOffset: cameraOffset,
            renderScale: oldRenderScale,
            renderOffset: oldRenderOffset,
            overscan: overscan
        )
        let refreshedTransform = BeckMapLayerTransform.transform(
            cameraScale: cameraScale,
            cameraOffset: cameraOffset,
            renderScale: cameraScale,
            renderOffset: cameraOffset,
            overscan: overscan
        )
        let previousPoint = CGPoint(
            x: mapPoint.x * oldRenderScale + oldRenderOffset.width + overscan,
            y: mapPoint.y * oldRenderScale + oldRenderOffset.height + overscan
        ).applying(previousTransform)
        let refreshedPoint = CGPoint(
            x: mapPoint.x * cameraScale + cameraOffset.width + overscan,
            y: mapPoint.y * cameraScale + cameraOffset.height + overscan
        ).applying(refreshedTransform)

        #expect(abs(previousPoint.x - refreshedPoint.x) < 0.000_001)
        #expect(abs(previousPoint.y - refreshedPoint.y) < 0.000_001)
    }

    @Test func aMovingPinchFocalPointRetainsTheSameMapLocation() {
        let initialScale: CGFloat = 0.4
        let initialOffset = CGSize(width: -500, height: -180)
        let initialFocalPoint = CGPoint(x: 180, y: 360)
        let mapPoint = CGPoint(
            x: (initialFocalPoint.x - initialOffset.width) / initialScale,
            y: (initialFocalPoint.y - initialOffset.height) / initialScale
        )
        let overscan: CGFloat = 320
        let cachedPoint = CGPoint(
            x: mapPoint.x * initialScale + initialOffset.width + overscan,
            y: mapPoint.y * initialScale + initialOffset.height + overscan
        )

        for step in 0...120 {
            let scale = initialScale * (1 + CGFloat(step) / 120)
            let focalPoint = CGPoint(
                x: initialFocalPoint.x + CGFloat(step) * 0.3,
                y: initialFocalPoint.y - CGFloat(step) * 0.2
            )
            let offset = CGSize(
                width: focalPoint.x - mapPoint.x * scale,
                height: focalPoint.y - mapPoint.y * scale
            )
            let transform = BeckMapLayerTransform.transform(
                cameraScale: scale,
                cameraOffset: offset,
                renderScale: initialScale,
                renderOffset: initialOffset,
                overscan: overscan
            )
            let displayedPoint = cachedPoint.applying(transform)

            #expect(abs(displayedPoint.x - focalPoint.x) < 0.000_001)
            #expect(abs(displayedPoint.y - focalPoint.y) < 0.000_001)
        }
    }

    @MainActor @Test func navigationFramesMoveEveryLayerWithoutInvalidatingViewObservation() {
        let camera = BeckMapLayerCamera()
        let layers = (0..<3).map { _ in CALayer() }
        let renderScale: CGFloat = 0.35
        let renderOffset = CGSize(width: -470, height: 125)
        let overscan: CGFloat = 320
        let invalidations = CameraObservationInvalidations()

        for layer in layers {
            camera.attach(
                layer: layer,
                renderScale: renderScale,
                renderOffset: renderOffset,
                overscan: overscan
            )
        }

        for frame in 0..<240 {
            withObservationTracking {
                _ = camera.scale
                _ = camera.offset
            } onChange: {
                invalidations.increment()
            }

            let scale = renderScale + CGFloat(frame) * 0.002
            let offset = CGSize(
                width: renderOffset.width + CGFloat(frame) * 1.5,
                height: renderOffset.height - CGFloat(frame) * 0.75
            )
            camera.update(scale: scale, offset: offset)

            for layer in layers {
                let point = CGPoint(x: 750, y: 525).applying(layer.affineTransform())
                let mapPoint = CGPoint(
                    x: (750 - renderOffset.width - overscan) / renderScale,
                    y: (525 - renderOffset.height - overscan) / renderScale
                )
                #expect(abs(point.x - (mapPoint.x * scale + offset.width)) < 0.000_001)
                #expect(abs(point.y - (mapPoint.y * scale + offset.height)) < 0.000_001)
                #expect(layer.animationKeys()?.isEmpty ?? true)
            }
        }

        #expect(invalidations.value == 0)
    }

    @MainActor @Test func reattachingARebasedLayerUsesItsNewRenderCamera() {
        let camera = BeckMapLayerCamera()
        let layer = CALayer()
        camera.attach(layer: layer, renderScale: 0.35, renderOffset: .zero, overscan: 320)
        camera.update(scale: 0.7, offset: CGSize(width: -500, height: -800))
        camera.attach(
            layer: layer,
            renderScale: 0.7,
            renderOffset: CGSize(width: -500, height: -800),
            overscan: 320
        )
        camera.update(scale: 0.7, offset: CGSize(width: -450, height: -780))

        #expect(layer.affineTransform() == CGAffineTransform(translationX: -270, y: -300))
    }

    @MainActor @Test func detachedLayersStopReceivingCameraMotion() {
        let camera = BeckMapLayerCamera()
        let detachedLayer = CALayer()
        let visibleLayer = CALayer()
        for layer in [detachedLayer, visibleLayer] {
            camera.attach(layer: layer, renderScale: 0.35, renderOffset: .zero, overscan: 320)
        }
        camera.update(scale: 0.35, offset: CGSize(width: 20, height: 40))
        let finalDetachedTransform = detachedLayer.affineTransform()
        camera.detach(layer: detachedLayer)
        camera.update(scale: 0.7, offset: CGSize(width: 60, height: 80))

        #expect(detachedLayer.affineTransform() == finalDetachedTransform)
        #expect(visibleLayer.affineTransform() != finalDetachedTransform)
    }

    @MainActor @Test func invalidCameraInputPreservesTheLastVisibleFrame() {
        let camera = BeckMapLayerCamera()
        let layer = CALayer()
        camera.attach(layer: layer, renderScale: 0.35, renderOffset: .zero, overscan: 320)
        let validOffset = CGSize(width: -50, height: 120)
        camera.update(scale: 0.7, offset: validOffset)
        let validTransform = layer.affineTransform()

        for invalidScale: CGFloat in [0, -1, .infinity, .nan] {
            camera.update(scale: invalidScale, offset: .zero)
        }
        camera.update(scale: 1, offset: CGSize(width: CGFloat.infinity, height: 0))
        camera.update(scale: 1, offset: CGSize(width: 0, height: CGFloat.nan))

        #expect(camera.scale == 0.7)
        #expect(camera.offset == validOffset)
        #expect(layer.affineTransform() == validTransform)
    }

    @MainActor @Test func immediateCameraTransitionsReachTheirTargetAndCompleteOnce() {
        for duration: TimeInterval in [0, -1, .infinity, .nan] {
            let animator = BeckMapCameraAnimator()
            var updates: [Double] = []
            var completions = 0
            animator.animate(
                duration: duration,
                easing: { $0 * $0 },
                update: { updates.append($0) },
                completion: { completions += 1 }
            )

            #expect(updates == [1])
            #expect(completions == 1)
            #expect(!animator.isAnimating)
        }
    }

    @MainActor @Test func cancellingCameraMotionReleasesCallbacksWithoutCompleting() {
        let animator = BeckMapCameraAnimator()
        weak var retainedProbe: CameraAnimationProbe?
        var completions = 0
        do {
            let probe = CameraAnimationProbe()
            retainedProbe = probe
            animator.animate(
                duration: 10,
                easing: { [probe] progress in
                    probe.updates += 1
                    return progress
                },
                update: { [probe] _ in probe.updates += 1 },
                completion: { completions += 1 }
            )
        }
        #expect(animator.isAnimating)
        #expect(retainedProbe != nil)
        animator.cancel()

        #expect(!animator.isAnimating)
        #expect(retainedProbe == nil)
        #expect(completions == 0)
    }

    @MainActor @Test func replacingAnImmediateTransitionSuppressesItsStaleCompletion() {
        let animator = BeckMapCameraAnimator()
        var oldCompletions = 0
        var replacementCompletions = 0
        animator.animate(
            duration: 0,
            easing: { $0 },
            update: { _ in
                animator.animate(
                    duration: 10,
                    easing: { $0 },
                    update: { _ in },
                    completion: { replacementCompletions += 1 }
                )
            },
            completion: { oldCompletions += 1 }
        )

        #expect(animator.isAnimating)
        #expect(oldCompletions == 0)
        animator.cancel()
        #expect(replacementCompletions == 0)
    }
}

@MainActor
private final class CameraAnimationProbe {
    var updates = 0
}

private final class CameraObservationInvalidations: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
