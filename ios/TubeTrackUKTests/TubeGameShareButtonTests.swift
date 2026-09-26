import SwiftUI
import Testing
import UIKit
@testable import TubeTrackUK

struct TubeGameShareButtonTests {
    @Test @MainActor func pausedGameShareButtonCreatesAnActivityControllerOnRepeatedTaps() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let item = TubeGameShareItem(image: image, title: "TubeTrack UK · 254 points")
        var preparationCount = 0
        var failed = false
        let host = RecordingHostingController(rootView:
            TimelineView(.animation(paused: true)) { _ in
                TubeGameShareButton(makeItem: {
                    preparationCount += 1
                    return item
                }, onFailure: { failed = true })
                .frame(height: 50)
            }
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        let button = try #require(findButton(in: host.view))
        for _ in 0..<2 {
            button.sendActions(for: .touchUpInside)
            #expect(preparationCount > 0)
            #expect(!failed)
            let activity = try #require(host.recordedActivity)
            #expect(item.activityViewController(activity, itemForActivityType: .copyToPasteboard) as? UIImage === image)
            #expect(item.activityViewControllerLinkMetadata(activity)?.title == item.title)
            host.recordedActivity = nil
        }
        #expect(preparationCount == 2)
    }

    @MainActor private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == "game.shareScore" { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
}

@MainActor
private final class RecordingHostingController<Content: View>: UIHostingController<Content> {
    var recordedActivity: UIActivityViewController?

    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        recordedActivity = viewControllerToPresent as? UIActivityViewController
        completion?()
    }
}
