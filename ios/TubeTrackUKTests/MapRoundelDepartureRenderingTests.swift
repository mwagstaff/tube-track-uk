import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor
final class MapRoundelDepartureRenderingTests: XCTestCase {
    func testBlackfriarsTappedServiceInLightDarkAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        var windows: [UIWindow] = []
        defer {
            for window in windows {
                window.isHidden = true
                window.rootViewController = nil
            }
            previousWindow?.makeKey()
        }
        let now = Date.now
        let arrivals = [
            TfLArrivalPrediction(id: "rail", vehicleId: nil, lineId: "national-rail:SE",
                stationName: "Blackfriars", naptanId: "910GBLFR", platformName: "Platform 4",
                direction: "southbound", destinationName: "Sevenoaks", destinationNaptanId: nil,
                towards: nil, expectedArrival: now.addingTimeInterval(360), timeToStation: 360,
                currentLocation: nil, scheduledDeparture: now.addingTimeInterval(360),
                serviceStatus: .onTime, operatorName: "Southeastern"),
            TfLArrivalPrediction(id: "thameslink", vehicleId: nil, lineId: "thameslink",
                stationName: "Blackfriars", naptanId: "910GBLFR", platformName: "Platform 2",
                direction: "southbound", destinationName: "Brighton", destinationNaptanId: nil,
                towards: nil, expectedArrival: now.addingTimeInterval(180), timeToStation: 180,
                currentLocation: nil)
        ]
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("large-text", .dark, .accessibility3)] {
            for prefersRail in [true, false] {
                let view = VStack(alignment: .leading, spacing: 16) {
                    Text("Blackfriars").font(.appHeadline())
                    StationDeparturesSection(lineIDs: [.circle, .district, .thameslink],
                        preferredLineID: prefersRail ? nil : .thameslink,
                        preferredOperatorID: prefersRail ? "national-rail:SE" : nil,
                        arrivals: arrivals, statuses: [])
                }
                .padding(20)
                .foregroundStyle(.primary)
                .frame(width: 390)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
                .environment(StationBoardActivityController())
                let height: CGFloat = size.isAccessibilitySize ? 750 : 360
                let frame = CGRect(x: 0, y: 0, width: 390, height: height)
                let host = UIHostingController(rootView: view.frame(height: height, alignment: .top).ignoresSafeArea())
                let window = UIWindow(windowScene: scene)
                windows.append(window)
                window.frame = frame
                window.rootViewController = host
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.makeKeyAndVisible()
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
                    XCTAssertTrue(host.view.drawHierarchy(in: frame, afterScreenUpdates: true))
                }
                XCTAssertGreaterThan(image.size.height, 150)
                let attachment = XCTAttachment(image: image)
                attachment.name = "blackfriars-\(prefersRail ? "southeastern" : "thameslink")-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
    }
}
