import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor
final class NationalRailMapRenderingTests: XCTestCase {
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
