import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor final class DeparturePreferencesRenderingTests: XCTestCase {
    func testPreferencesInLightDarkAndLargeText() async throws {
        let suite = "departure-preferences-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for (name, custom, scheme, size) in [
            ("default", false, ColorScheme.light, DynamicTypeSize.large),
            ("custom", true, .dark, .large),
            ("accessibility", true, .dark, .accessibility3)
        ] {
            var preferences = DepartureDisplayPreferences()
            preferences.matchesRealWorld = !custom
            defaults.set(String(data: try JSONEncoder().encode(preferences), encoding: .utf8),
                         forKey: DepartureDisplayStorage.key)
            let view = NavigationStack { PreferencesScreen(defaults: defaults) }
                .environment(app).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            if name == "accessibility", let scroll = scrollView(in: host.view) {
                scroll.setContentOffset(CGPoint(x: 0, y: 720), animated: false)
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutIfNeeded()
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "departure-preferences-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/departure-preferences-\(name).png"))
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
