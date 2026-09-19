import SwiftUI
import UIKit
import QuartzCore

enum BeckMapGesturePhase: Equatable {
    case began
    case changed
    case decelerating
    case interrupted
    case ended
}

struct BeckMapGestureSurface: UIViewRepresentable {
    let allowsMomentum: Bool
    /// Returns true when touch-down interrupted a programmatic camera animation.
    let onTouchDown: () -> Bool
    let onInteractionChange: (Bool) -> Void
    let onPan: (CGSize, BeckMapGesturePhase) -> Void
    let onPinch: (CGFloat, CGPoint, BeckMapGesturePhase) -> Void
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = TouchSurface()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        view.onTouchDown = { [weak coordinator = context.coordinator] in
            coordinator?.touchBegan()
        }
        view.onTouchesEnded = { [weak coordinator = context.coordinator] in
            coordinator?.touchesEnded()
        }

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan)
        tap.require(toFail: pinch)

        let recognizers: [UIGestureRecognizer] = [pan, pinch, tap]
        for recognizer in recognizers {
            // This transparent surface also observes physical touch-down/up to
            // catch a coasting map before UIKit decides between a tap and a pan.
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopAllMotion()
    }

    private final class TouchSurface: UIView {
        var onTouchDown: (() -> Void)?
        var onTouchesEnded: (() -> Void)?
        private var activeTouches: Set<UITouch> = []

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let wasEmpty = activeTouches.isEmpty
            activeTouches.formUnion(touches)
            if wasEmpty { onTouchDown?() }
            super.touchesBegan(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.subtract(touches)
            if activeTouches.isEmpty { onTouchesEnded?() }
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.subtract(touches)
            if activeTouches.isEmpty { onTouchesEnded?() }
            super.touchesCancelled(touches, with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private enum PanMotion {
            case idle
            case tracking
            case decelerating
        }

        var parent: BeckMapGestureSurface
        private var panMotion: PanMotion = .idle
        private var displayLink: CADisplayLink?
        private var deliveredTranslation = CGSize.zero
        private var releaseVelocity = CGPoint.zero
        private var decelerationElapsed: TimeInterval = 0
        private var isTrackingPinch = false
        private var deliveredPinchScale: CGFloat = 1
        private var deliveredPinchLocation = CGPoint.zero
        private var lastReportedInteractionState = false
        private var awaitingGestureAfterInterruption = false

        var isDecelerating: Bool { panMotion == .decelerating }
        var isDisplayLinkActive: Bool { displayLink != nil }

        init(parent: BeckMapGestureSurface) {
            self.parent = parent
        }

        func touchBegan() {
            let interruptedAnimation = parent.onTouchDown()
            guard panMotion == .decelerating || interruptedAnimation else { return }
            // Stop under the finger immediately. The eventual gesture, tap or
            // cancellation publishes the final viewport, not this handover.
            awaitingGestureAfterInterruption = true
            clearPanMotion()
            parent.onPan(.zero, .interrupted)
            notifyInteractionIfNeeded()
        }

        func touchesEnded() {
            guard awaitingGestureAfterInterruption else { return }
            finishPanMotion()
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            handlePan(
                state: recognizer.state,
                translation: CGSize(width: translation.x, height: translation.y),
                velocity: recognizer.state == .ended ? recognizer.velocity(in: view) : .zero,
                screen: view.window?.screen
            )
        }

        func handlePan(
            state: UIGestureRecognizer.State,
            translation: CGSize,
            velocity: CGPoint = .zero,
            screen: UIScreen? = nil
        ) {
            guard !isTrackingPinch else { return }
            switch state {
            case .began:
                clearPanMotion()
                awaitingGestureAfterInterruption = false
                deliveredTranslation = .zero
                panMotion = .tracking
                parent.onPan(.zero, .began)
                // UIKit has already accumulated movement when recognition
                // begins. Apply it before updating any surrounding SwiftUI UI.
                deliverTranslation(translation)
                notifyInteractionIfNeeded()
            case .changed:
                guard panMotion == .tracking else { return }
                deliverTranslation(translation)
            case .ended:
                guard panMotion == .tracking else { return }
                deliverTranslation(translation)
                if parent.allowsMomentum,
                   let initialVelocity = BeckMapMomentumPolicy.initialVelocity(from: velocity) {
                    releaseVelocity = initialVelocity
                    decelerationElapsed = 0
                    panMotion = .decelerating
                    parent.onPan(.zero, .decelerating)
                    startDisplayLink(on: screen)
                    // Momentum is passive animation, not an active touch.
                    // Release map chrome immediately so its controls respond
                    // to the very next tap instead of consuming that tap to
                    // stop the coast first.
                    notifyInteractionIfNeeded()
                } else {
                    finishPanMotion()
                }
            case .cancelled, .failed:
                guard panMotion == .tracking else { return }
                deliverTranslation(translation)
                finishPanMotion()
            default:
                break
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            handlePinch(
                state: recognizer.state,
                magnification: recognizer.scale,
                location: recognizer.location(in: view)
            )
        }

        func handlePinch(state: UIGestureRecognizer.State, magnification: CGFloat, location: CGPoint) {
            switch state {
            case .began:
                if panMotion != .idle {
                    clearPanMotion()
                    parent.onPan(.zero, .interrupted)
                }
                awaitingGestureAfterInterruption = false
                isTrackingPinch = true
                deliveredPinchScale = 1
                deliveredPinchLocation = location
                parent.onPinch(magnification, location, .began)
                deliverPinch(magnification, location: location)
                notifyInteractionIfNeeded()
            case .changed:
                guard isTrackingPinch else { return }
                deliverPinch(magnification, location: location)
            case .ended, .cancelled, .failed:
                guard isTrackingPinch else { return }
                deliverPinch(magnification, location: location)
                isTrackingPinch = false
                parent.onPinch(magnification, location, .ended)
                notifyInteractionIfNeeded()
            default:
                break
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            handleTap(at: recognizer.location(in: view))
        }

        func handleTap(at location: CGPoint) {
            if panMotion != .idle || awaitingGestureAfterInterruption {
                finishPanMotion()
            }
            parent.onTap(location)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        private func deliverTranslation(_ translation: CGSize) {
            guard translation != deliveredTranslation else { return }
            deliveredTranslation = translation
            parent.onPan(translation, .changed)
        }

        private func deliverPinch(_ scale: CGFloat, location: CGPoint) {
            guard scale != deliveredPinchScale || location != deliveredPinchLocation else { return }
            deliveredPinchScale = scale
            deliveredPinchLocation = location
            parent.onPinch(scale, location, .changed)
        }

        private func startDisplayLink(on screen: UIScreen?) {
            // Direct manipulation already arrives on UIKit's input cadence.
            // A second scheduler adds input latency; only inertia needs one.
            let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            let maximumFramesPerSecond = Float(screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(60, maximumFramesPerSecond),
                maximum: maximumFramesPerSecond,
                preferred: maximumFramesPerSecond
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func displayLinkDidFire(_ link: CADisplayLink) {
            guard link === displayLink, panMotion == .decelerating else { return }
            let frameDuration = min(1.0 / 20.0, max(1.0 / 240.0, link.targetTimestamp - link.timestamp))
            let nextVelocity = BeckMapMomentumPolicy.attenuatedVelocity(releaseVelocity, over: frameDuration)
            parent.onPan(
                BeckMapMomentumPolicy.translation(from: releaseVelocity, to: nextVelocity, over: frameDuration),
                .decelerating
            )
            releaseVelocity = nextVelocity
            decelerationElapsed += frameDuration
            if BeckMapMomentumPolicy.shouldStop(velocity: nextVelocity, elapsed: decelerationElapsed) {
                finishPanMotion()
            }
        }

        private func clearPanMotion() {
            panMotion = .idle
            releaseVelocity = .zero
            decelerationElapsed = 0
            displayLink?.invalidate()
            displayLink = nil
        }

        private func finishPanMotion() {
            clearPanMotion()
            awaitingGestureAfterInterruption = false
            parent.onPan(.zero, .ended)
            notifyInteractionIfNeeded()
        }

        private func notifyInteractionIfNeeded() {
            let isInteracting = panMotion == .tracking || isTrackingPinch || awaitingGestureAfterInterruption
            reportInteraction(isInteracting)
        }

        private func reportInteraction(_ isInteracting: Bool) {
            guard isInteracting != lastReportedInteractionState else { return }
            lastReportedInteractionState = isInteracting
            parent.onInteractionChange(isInteracting)
        }

        func stopAllMotion() {
            clearPanMotion()
            awaitingGestureAfterInterruption = false
            isTrackingPinch = false
            notifyInteractionIfNeeded()
        }
    }
}
