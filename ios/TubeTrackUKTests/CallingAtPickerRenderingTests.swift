import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor final class CallingAtPickerRenderingTests: XCTestCase {
    func testSharedPickersInLightDarkAndLargeText() async throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for (name, scheme, size) in [
            ("light", ColorScheme.light, DynamicTypeSize.large),
            ("dark", .dark, .large),
            ("large-text", .dark, .accessibility3)
        ] {
            for callingAt in [false, true] {
                let picker = callingAt
                    ? AnyView(DepartureEndpointPicker(stops: DepartureStop.bundled.filter { $0.mode == "rail" },
                              selectedIDs: [], title: "Calling at") { _ in })
                    : AnyView(StationSearchSheet(graph: graph, selectedStationID: nil, title: "Destination") { _ in })
                let host = UIHostingController(rootView: picker
                    .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
                window.rootViewController = host
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(500))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let label = "\(callingAt ? "calling-at" : "journey")-\(name)"
                let attachment = XCTAttachment(image: image)
                attachment.name = label
                attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(label).png"))
            }
        }
    }
}
