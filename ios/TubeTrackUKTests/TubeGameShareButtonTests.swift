import SwiftUI
import Testing
import UIKit
@testable import TubeTrackUK

struct TubeGameShareButtonTests {
    @Test @MainActor func tapPresentsImageShareSheetFromPausedGameAndCanReopen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let item = TubeGameShareItem(image: image, title: "TubeTrack UK · 254 points")
        var preparationCount = 0
        var failed = false
        let host = UIHostingController(rootView:
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
            try await Task.sleep(for: .seconds(1))
            let activity = try #require(host.presentedViewController as? UIActivityViewController)
            #expect(activity.viewIfLoaded?.window != nil)
            #expect(item.activityViewController(activity, itemForActivityType: .copyToPasteboard) as? UIImage === image)
            #expect(item.activityViewControllerLinkMetadata(activity)?.title == item.title)
            #expect(!failed)
            host.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(preparationCount == 2)
    }

    @MainActor private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == "game.shareScore" { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
}
