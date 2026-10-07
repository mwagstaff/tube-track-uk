import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor
final class NationalRailMapRenderingTests: XCTestCase {
    func testEveryReferencePierAtDetailAndOverviewZoom() async throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let artwork = try XCTUnwrap(document.referenceArtwork)
        let cache = BeckMapReferenceRenderCache(artwork)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let defaultsName = "GreenwichPierRendering.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .nearMe
        // Use a reviewed time outside opening hours, so live status banners
        // cannot obscure the cable geometry or make these captures vary.
        state.cableCar.updatePresentation(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T05:00:00Z")))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let camera = BeckMapLayerCamera()
        var locations: [(String, CGPoint, CGFloat)] = (artwork.riverAnchors ?? [])
            .filter { $0.walkingLinksInArtwork == true }
            .map { ($0.id, $0.markerPoint, 1.5) }
        locations += (artwork.additionalRiverPiers ?? []).map {
            ($0.id, CGPoint(x: $0.centre.x, y: $0.centre.y), 1.5)
        }
        locations += [("london-overview", CGPoint(x: 1220, y: 1112), 0.15),
                      ("selected-waterloo-overview", CGPoint(x: 1200, y: 1130), 0.35),
                      ("london-bridge-link", CGPoint(x: 1500, y: 1098), 1.5),
                      ("cable-car-terminals", CGPoint(x: 1996, y: 1046), 1.1),
                      ("cable-car-overview", CGPoint(x: 1996, y: 1046), 0.5)]
        for (name, centre, scale) in locations {
            let size = name == "london-bridge-link" ? CGSize(width: 440, height: 320) : CGSize(width: 390, height: 240)
            if name == "selected-waterloo-overview" {
                state.river.select(try XCTUnwrap(state.river.network.pier("930GWMP")))
            } else {
                state.river.clearSelection()
            }
            let offset = CGSize(width: size.width / 2 - centre.x * scale,
                                height: size.height / 2 - centre.y * scale)
            camera.update(scale: scale, offset: offset)
            let blocked = (artwork.stationLabels ?? []).map { label in
                CGRect(x: (label.centre.x - label.size.width / 2) * scale + offset.width,
                       y: (label.centre.y - label.size.height / 2) * scale + offset.height,
                       width: label.size.width * scale, height: label.size.height * scale).insetBy(dx: -2, dy: -2)
            }
            for scheme in [ColorScheme.light, .dark] {
                let palette = BeckMapPalette.resolve(for: scheme)
                let typeScale: CGFloat = scheme == .dark ? 1.6 : 1
                let view = ZStack {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
                        context.translateBy(x: offset.width, y: offset.height)
                        context.scaleBy(x: scale, y: scale)
                        cache.draw(context: &context, palette: palette, isDark: scheme == .dark)
                    }
                    BeckRiverLayer(document: document, camera: camera, scale: scale, offset: offset,
                                   overscan: 0, canvasSize: size, typeScale: typeScale, blocked: blocked)
                    if name.hasPrefix("cable-car-") {
                        BeckCableCarLayer(document: document, camera: camera, scale: scale, offset: offset,
                                          overscan: 0, canvasSize: size, typeScale: typeScale)
                    }
                }
                .frame(width: size.width, height: size.height)
                .environment(state)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, scheme == .dark ? .accessibility3 : .large)
                let host = UIHostingController(rootView: view.ignoresSafeArea())
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(100))
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    XCTAssertTrue(host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "pier-\(name)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testCombinedVectorArtworkInLightAndDark() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let artwork = try XCTUnwrap(document.referenceArtwork)
        let cache = BeckMapReferenceRenderCache(artwork)
        for scheme in [ColorScheme.light, .dark] {
            let palette = BeckMapPalette.resolve(for: scheme)
            let view = Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
                context.scaleBy(x: 0.5, y: 0.5)
                cache.draw(context: &context, palette: palette, isDark: scheme == .dark)
            }
            .frame(width: document.artworkSize.width / 2, height: document.artworkSize.height / 2)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "combined-national-rail-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
