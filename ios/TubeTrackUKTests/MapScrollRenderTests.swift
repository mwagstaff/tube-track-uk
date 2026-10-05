import SwiftUI
import MapKit
import Testing
import UIKit
@testable import TubeTrackUK

@Suite(.serialized)
@MainActor
struct MapScrollRenderTests {
    @Test func retainedCanvasResizesEvenWhenContentKeyDoesNotChange() {
        let controller = BeckMapCanvasController<Int>()
        let camera = BeckMapLayerCamera()
        for size in [CGSize(width: 480, height: 480), CGSize(width: 920, height: 1436)] {
            controller.update(
                key: 0, camera: camera, renderScale: 1, renderOffset: .zero,
                overscan: 240, canvasSize: size, colorScheme: .light,
                renderer: { _, _ in }
            )
            #expect(controller.view.subviews.first?.bounds.size == size)
            #expect(controller.children.first?.view.bounds.size == size)
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
            camera.update(scale: scale, offset: CGSize(width: -100, height: -200))
            controller.update(
                key: index + 1, camera: camera, renderScale: scale,
                renderOffset: camera.offset, overscan: 240, canvasSize: canvasSize,
                colorScheme: .light, renderer: { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0, blue: 0)))
                }
            )
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.children.first?.view.bounds.size == canvasSize)
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
