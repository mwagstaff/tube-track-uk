import SwiftUI
import Testing
import UIKit
@testable import TubeTrackUK

struct TubeGameFireworksTests {
    @Test @MainActor func fireworksKeepAnimatingInsideStoppedGameTimeline() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            TimelineView(.animation(paused: true)) { _ in
                ZStack {
                    Color.black
                    TubeGameFireworks()
                }
            }
            .environment(\.scenePhase, .active)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .seconds(1))
        let first = try #require(capture(host.view).pngData())
        try await Task.sleep(for: .seconds(1))
        let second = try #require(capture(host.view).pngData())
        #expect(first != second, "Fireworks must advance even when the parent game timeline is paused")
        #expect(second.count > 20_000, "The full-screen canvas must contain visible bursts")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try first.write(to: directory.appendingPathComponent("fireworks-first.png"))
        try second.write(to: directory.appendingPathComponent("fireworks-second.png"))
    }

    @MainActor private func capture(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }
}
