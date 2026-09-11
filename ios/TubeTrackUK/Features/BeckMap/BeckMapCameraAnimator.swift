import QuartzCore
import UIKit

/// Advances a camera transition on display refreshes without a sleeping task or
/// fixed frame count. The caller owns the camera and its reduced-motion policy.
@MainActor
final class BeckMapCameraAnimator {
    private var displayLink: CADisplayLink?
    private let frameRateRange: CAFrameRateRange
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var generation: UInt = 0
    private var easing: ((Double) -> Double)?
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?

    var isAnimating: Bool {
        displayLink != nil
    }

    init(screen: UIScreen? = nil) {
        if let screen {
            let maximumFramesPerSecond = Float(max(1, screen.maximumFramesPerSecond))
            frameRateRange = CAFrameRateRange(
                minimum: min(60, maximumFramesPerSecond),
                maximum: maximumFramesPerSecond,
                preferred: maximumFramesPerSecond
            )
        } else {
            // The system default follows the display's maximum refresh rate.
            frameRateRange = .default
        }
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    func animate(
        duration: TimeInterval,
        easing: @escaping (Double) -> Double,
        update: @escaping (Double) -> Void,
        completion: @escaping () -> Void
    ) {
        cancel()
        let currentGeneration = generation

        guard duration.isFinite, duration > 0 else {
            update(1)
            guard generation == currentGeneration else { return }
            completion()
            return
        }

        self.duration = duration
        self.easing = easing
        self.update = update
        self.completion = completion
        startedAt = CACurrentMediaTime()

        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = frameRateRange
        displayLink = link
        // Continue animating while UIKit is tracking another control or gesture.
        link.add(to: .main, forMode: .common)
        update(0)
    }

    /// Cancelling releases callbacks and never invokes the completion handler.
    func cancel() {
        generation &+= 1
        displayLink?.invalidate()
        displayLink = nil
        easing = nil
        update = nil
        completion = nil
    }

    private func tick(_ link: CADisplayLink) {
        guard link === displayLink, let easing, let update else { return }
        let currentGeneration = generation
        // Target timestamps share CACurrentMediaTime's monotonic clock. Elapsed
        // time keeps motion at the correct speed across missed or variable frames.
        let progress = min(1, max(0, (link.targetTimestamp - startedAt) / duration))
        let easedProgress = progress == 1 ? 1 : easing(progress)
        guard generation == currentGeneration else { return }
        update(easedProgress)

        // An update may cancel this transition or start a replacement transition.
        guard generation == currentGeneration, progress == 1 else { return }
        let completed = completion
        cancel()
        completed?()
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: BeckMapCameraAnimator?

        init(owner: BeckMapCameraAnimator) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}
