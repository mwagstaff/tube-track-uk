import SwiftUI
import MapKit
import Testing
import UIKit
@testable import TubeTrackUK

@Suite(.serialized)
@MainActor
struct MapScrollRenderTests {
    @Test func completeRasterIsAvailableBeforeWindowAttachmentAndCameraMotionDoesNotRedraw() throws {
        let controller = BeckMapCanvasController<Int>()
        let camera = BeckMapLayerCamera()
        let size = CGSize(width: 920, height: 1436)
        var draws = 0
        controller.update(
            key: 0, camera: camera, renderScale: 1, renderOffset: .zero,
            overscan: 240, canvasSize: size, colorScheme: .light, displayScale: 3,
            renderer: { context, size in
                draws += 1
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red))
                context.fill(Path(CGRect(x: size.width / 2, y: size.height / 2,
                                         width: size.width / 2, height: size.height / 2)),
                             with: .color(.blue))
            }
        )
        let layer = try #require(controller.view.subviews.first?.layer)
        let raster = try #require(layer.contents) as! CGImage
        #expect(raster.width == 2760)
        #expect(raster.height == 4308)
        #expect(layer.contentsScale == 3)
        var pixels = [UInt8](repeating: 0, count: 16)
        let context = try #require(CGContext(data: &pixels, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(stride(from: 3, to: 16, by: 4).allSatisfy { pixels[$0] == 255 })
        #expect(stride(from: 0, to: 16, by: 4).filter { pixels[$0 + 2] > 200 }.count == 1)
        let completedDraws = draws
        for step in 0..<120 {
            camera.update(scale: 1 + CGFloat(step) / 120,
                          offset: CGSize(width: -step * 10, height: -step * 20))
        }
        #expect(draws == completedDraws)
        #expect((layer.contents as AnyObject?) === raster)

        // A provisional zero-size layout must not discard the last complete
        // buffer or mark the replacement key as rendered.
        controller.update(
            key: 1, camera: camera, renderScale: 1, renderOffset: .zero,
            overscan: 240, canvasSize: .zero, colorScheme: .light,
            renderer: { _, _ in Issue.record("Invalid layout should not render") }
        )
        #expect((layer.contents as AnyObject?) === raster)
    }

    @Test func retainedRasterRefreshesAppearanceAndDisplayScaleWithoutAContentChange() throws {
        let controller = BeckMapCanvasController<Int>()
        let camera = BeckMapLayerCamera()
        let size = CGSize(width: 100, height: 100)
        var previous: CGImage?
        for (appearance, scale) in [(ColorScheme.light, CGFloat(2)), (.dark, 2), (.dark, 3)] {
            controller.update(
                key: 0, camera: camera, renderScale: 1, renderOffset: .zero,
                overscan: 0, canvasSize: size, colorScheme: appearance, displayScale: scale,
                renderer: { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary))
                }
            )
            let raster = try #require(controller.view.subviews.first?.layer.contents) as! CGImage
            #expect(raster !== previous)
            #expect(raster.width == Int(size.width * scale))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(raster, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            #expect(appearance == .dark ? pixel[0] > 240 : pixel[0] < 20)
            previous = raster
        }
    }

    @Test func retainedCanvasKeepsOverscanPixelsWhenMovedWithoutRedrawing() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let camera = BeckMapLayerCamera()
        camera.update(scale: 1, offset: .zero)
        let host = UIHostingController(rootView: GeometryReader { proxy in
            BeckMapRetainedCanvas(
                key: 0, camera: camera, renderScale: 1, renderOffset: .zero,
                overscan: 240,
                canvasSize: CGSize(width: proxy.size.width + 480, height: proxy.size.height + 480),
                colorScheme: .light,
                renderer: { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0, blue: 0)))
                }
            ).clipped()
        }.ignoresSafeArea())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(100))
        for offset in [CGSize.zero, CGSize(width: -190, height: -190), CGSize(width: 190, height: 190)] {
            camera.update(scale: 1, offset: offset)
            try await Task.sleep(for: .milliseconds(50))
            let viewport = host.view.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: viewport, format: format).image { _ in
                host.view.drawHierarchy(in: viewport, afterScreenUpdates: true)
            }
            let cgImage = try #require(image.cgImage)
            for x in [0.05, 0.5, 0.95] {
                for y in [0.05, 0.5, 0.95] {
                    var pixel = [UInt8](repeating: 0, count: 4)
                    let context = try #require(CGContext(data: &pixel, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.translateBy(x: -viewport.width * x, y: -viewport.height * y)
                    context.draw(cgImage, in: viewport)
                    #expect(pixel[0] > 240 && pixel[1] < 20 && pixel[2] < 20,
                            "Missing overscan at \(x), \(y), offset \(offset): \(pixel)")
                }
            }
        }
    }

    @Test func launchAtCityThameslinkRendersCompleteArtwork() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = TubeAppState(monitorsConnectivity: false)
        state.setNetworkAvailable(false)
        state.graph = try TubeGraph.bundled()
        let host = UIHostingController(rootView: BeckMapScreen(
            resetToken: 0,
            locationFocusRequest: MapLocationFocusRequest(id: 1, latitude: 51.5143, longitude: -0.1039, snappedStationID: nil),
            contentVerticalBias: 0,
            onUserZoomIn: {}, onInteractionChange: { _ in }, onBackgroundTap: {}
        ).environment(state).environment(UserLocationProvider()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .seconds(3))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        // The reported failure leaves only the upper-left of this camera drawn.
        // Require ink in every quadrant of the actual City Thameslink artwork.
        var pixels = [UInt8](repeating: 0, count: 80 * 160 * 4)
        let context = try #require(CGContext(data: &pixels, width: 80, height: 160,
            bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 80, height: 160))
        for column in 0..<2 {
            for row in 0..<2 {
                let ink = (row * 80..<(row + 1) * 80).reduce(0) { count, y in
                    count + (column * 40..<(column + 1) * 40).filter { x in
                        let index = (y * 80 + x) * 4
                        return pixels[index..<index + 3].min()! < 180
                    }.count
                }
                #expect(ink > 100, "Missing artwork in quadrant \(column), \(row)")
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-city-launch.png")
        try #require(image.pngData()).write(to: url)
        print("City launch render: \(url.path)")

    }

    @Test func retainedCanvasResizesEvenWhenContentKeyDoesNotChange() throws {
        let controller = BeckMapCanvasController<Int>()
        let camera = BeckMapLayerCamera()
        for size in [CGSize(width: 480, height: 480), CGSize(width: 920, height: 1436)] {
            controller.update(
                key: 0, camera: camera, renderScale: 1, renderOffset: .zero,
                overscan: 240, canvasSize: size, colorScheme: .light,
                renderer: { _, _ in }
            )
            #expect(controller.view.subviews.first?.bounds.size == size)
            let image = try #require(controller.view.subviews.first?.layer.contents) as! CGImage
            #expect(image.width == Int(size.width))
            #expect(image.height == Int(size.height))
        }
    }

    @Test func retainedCanvasCoversViewportAfterLaunchAndCameraRebase() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = BeckMapCanvasController<Int>()
        let camera = BeckMapLayerCamera()
        // The first representable update can run before its window has laid out.
        controller.update(
            key: 0, camera: camera, renderScale: 0.35, renderOffset: .zero,
            overscan: 240, canvasSize: CGSize(width: 480, height: 480),
            colorScheme: .light, renderer: { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0, blue: 0)))
            }
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        let viewport = controller.view.bounds.size
        let canvasSize = CGSize(width: viewport.width + 480, height: viewport.height + 480)
        for (index, scale) in [CGFloat(0.35), 1.4, 0.6].enumerated() {
            // Move the old render surface entirely away before replacing its
            // camera, as a startup location focus can do in a single frame.
            camera.update(scale: scale, offset: CGSize(width: -10_000, height: -20_000))
            try await Task.sleep(for: .milliseconds(30))
            camera.update(scale: scale, offset: CGSize(width: -100, height: -200))
            controller.update(
                key: index + 1, camera: camera, renderScale: scale,
                renderOffset: camera.offset, overscan: 240, canvasSize: canvasSize,
                colorScheme: .light, renderer: { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0, blue: 0)))
                }
            )
            try await Task.sleep(for: .milliseconds(100))
            let raster = try #require(controller.view.subviews.first?.layer.contents) as! CGImage
            #expect(raster.width == Int(canvasSize.width))
            #expect(raster.height == Int(canvasSize.height))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: viewport, format: format).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let cgImage = try #require(image.cgImage)
            for x in [0.1, 0.5, 0.9] {
                for y in [0.1, 0.5, 0.9] {
                    var pixel = [UInt8](repeating: 0, count: 4)
                    let context = try #require(CGContext(
                        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.translateBy(x: -viewport.width * x, y: -viewport.height * y)
                    context.draw(cgImage, in: CGRect(origin: .zero, size: viewport))
                    #expect(pixel[0] > 240 && pixel[1] < 20 && pixel[2] < 20,
                            "Missing canvas at \(x), \(y), rebase \(index): \(pixel)")
                }
            }
        }
    }

    @Test func repeatedArtworkRebasesPreserveCameraAndRenderInBothAppearances() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = TubeAppState(monitorsConnectivity: false)
        state.setNetworkAvailable(false)
        state.graph = try TubeGraph.bundled()
        let location = UserLocationProvider()
        let host = UIHostingController(rootView: BeckMapScreen(
            resetToken: 0, locationFocusRequest: nil, contentVerticalBias: 0,
            onUserZoomIn: {}, onInteractionChange: { _ in }, onBackgroundTap: {}
        ).environment(state).environment(location))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for _ in 0..<100 {
            if state.beckMapCameraSnapshot != nil, coordinator(in: host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let initial = try #require(state.beckMapCameraSnapshot)
        let gestures = try #require(coordinator(in: host.view))
        let anchor = CGPoint(x: initial.viewportWidth / 2, y: initial.viewportHeight / 2)
        gestures.handlePinch(state: .began, magnification: 1, location: anchor)
        gestures.handlePinch(state: .ended, magnification: 0.6 / initial.scale, location: anchor)
        try await Task.sleep(for: .milliseconds(100))
        let zoomed = try #require(state.beckMapCameraSnapshot)
        #expect(abs(zoomed.scale - 0.6) < 0.000_001)

        // Cross several 192-point render-buffer boundaries, then return. This
        // exercises real retained canvases, rather than only camera arithmetic.
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            gestures.handlePan(state: .began, translation: .zero)
            for step in 1...24 {
                gestures.handlePan(state: .changed, translation: CGSize(width: step * 20, height: step * 5))
                try await Task.sleep(for: .milliseconds(16))
            }
            gestures.handlePan(state: .ended, translation: .zero)
            try await Task.sleep(for: .milliseconds(100))
            #expect(state.beckMapCameraSnapshot == zoomed)
            #expect(coordinator(in: host.view) === gestures)

            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let data = try #require(image.pngData())
            #expect(data.count > 10_000)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-scroll-\(style.rawValue).png")
            try data.write(to: url)
            print("Map scroll render: \(url.path)")
        }
    }

    @Test func geographicLongPansRetainInstalledAnnotations() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = TubeAppState(monitorsConnectivity: false)
        state.setNetworkAvailable(false)
        state.graph = try TubeGraph.bundled()
        state.mapPresentationMode = .realWorld
        let host = UIHostingController(rootView: RealWorldMapScreen(
            resetToken: 0, locationFocusRequest: nil,
            onResetAvailabilityChange: { _ in }, onOverviewOpacityChange: { _ in },
            screenFurnitureOpacity: 1, onInteractionChange: { _ in }, onUserInteraction: {}
        ).environment(state).environment(UserLocationProvider()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for _ in 0..<100 {
            if mapView(in: host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let map = try #require(mapView(in: host.view))
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.008)
        ), animated: false)
        for _ in 0..<100 {
            if map.annotations.count > 200 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        let installed = Set(map.annotations.filter { !($0 is MKUserLocation) }.map { ObjectIdentifier($0) })
        #expect(installed.count > 200)
        // Many screens east/west without changing zoom. Rebuilding Map content
        // would replace SwiftUI's annotation objects and trigger layout again.
        for longitude in [-0.3, 0.1, -0.12] {
            map.setCenter(CLLocationCoordinate2D(latitude: 51.5, longitude: longitude), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            let current = Set(map.annotations.filter { !($0 is MKUserLocation) }.map { ObjectIdentifier($0) })
            // MapKit can finish adding auxiliary annotations asynchronously.
            // Every object already installed must survive the camera move.
            #expect(installed.isSubset(of: current))
        }
    }

    private func mapView(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { mapView(in: $0) }.first
    }

    private func coordinator(in view: UIView) -> BeckMapGestureSurface.Coordinator? {
        for gesture in view.gestureRecognizers ?? [] {
            if let coordinator = gesture.delegate as? BeckMapGestureSurface.Coordinator { return coordinator }
        }
        return view.subviews.lazy.compactMap { coordinator(in: $0) }.first
    }
}
