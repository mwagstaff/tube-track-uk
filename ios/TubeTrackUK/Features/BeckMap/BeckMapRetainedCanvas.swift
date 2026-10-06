import SwiftUI
import UIKit

enum BeckMapLayerTransform {
    /// The canvas is drawn at a fixed camera with padding on every edge. Motion
    /// transforms those pixels; it never changes SwiftUI layout or draws paths.
    static func transform(
        cameraScale: CGFloat,
        cameraOffset: CGSize,
        renderScale: CGFloat,
        renderOffset: CGSize,
        overscan: CGFloat
    ) -> CGAffineTransform {
        let ratio = cameraScale / max(0.000_001, renderScale)
        return CGAffineTransform(
            a: ratio, b: 0, c: 0, d: ratio,
            tx: cameraOffset.width - (renderOffset.width + overscan) * ratio,
            ty: cameraOffset.height - (renderOffset.height + overscan) * ratio
        )
    }
}

/// Deliberately not Observable. Gesture frames belong to Core Animation, not
/// the map's SwiftUI dependency graph. Only a new render camera invalidates it.
@MainActor
final class BeckMapLayerCamera {
    private(set) var scale: CGFloat = 0.35
    private(set) var offset: CGSize = .zero

    private struct Surface {
        weak var layer: CALayer?
        let scale: CGFloat
        let offset: CGSize
        let overscan: CGFloat
    }
    private var surfaces: [Surface] = []
    private struct Anchor {
        weak var layer: CALayer?
        let point: CGPoint
    }
    private var anchors: [Anchor] = []

    func attach(layer: CALayer, at point: CGPoint) {
        anchors.removeAll { $0.layer == nil || $0.layer === layer }
        anchors.append(Anchor(layer: layer, point: point))
        update(scale: scale, offset: offset)
    }

    func update(scale: CGFloat, offset: CGSize) {
        guard scale.isFinite, scale > 0,
              offset.width.isFinite, offset.height.isFinite else { return }
        self.scale = scale
        self.offset = offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in surfaces {
            apply(surface)
        }
        for anchor in anchors {
            anchor.layer?.position = CGPoint(
                x: anchor.point.x * scale + offset.width,
                y: anchor.point.y * scale + offset.height
            )
        }
        CATransaction.commit()
    }

    func attach(layer: CALayer, renderScale: CGFloat, renderOffset: CGSize, overscan: CGFloat) {
        surfaces.removeAll { $0.layer == nil || $0.layer === layer }
        let surface = Surface(layer: layer, scale: renderScale, offset: renderOffset, overscan: overscan)
        surfaces.append(surface)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(surface)
        CATransaction.commit()
    }

    func detach(layer: CALayer) {
        anchors.removeAll { $0.layer == nil || $0.layer === layer }
        surfaces.removeAll { $0.layer == nil || $0.layer === layer }
    }

    private func apply(_ surface: Surface) {
        surface.layer?.setAffineTransform(BeckMapLayerTransform.transform(
            cameraScale: scale,
            cameraOffset: offset,
            renderScale: surface.scale,
            renderOffset: surface.offset,
            overscan: surface.overscan
        ))
    }
}

/// Retains a complete raster while its layer moves at display cadence.
/// Only content/cache changes render; camera motion only transforms the layer.
struct BeckMapRetainedCanvas<Key: Equatable>: UIViewControllerRepresentable {
    @Environment(\.displayScale) private var displayScale
    let key: Key
    let camera: BeckMapLayerCamera
    let renderScale: CGFloat
    let renderOffset: CGSize
    let overscan: CGFloat
    let canvasSize: CGSize
    let colorScheme: ColorScheme
    let renderer: (inout GraphicsContext, CGSize) -> Void

    func makeUIViewController(context: Context) -> BeckMapCanvasController<Key> {
        BeckMapCanvasController()
    }

    func updateUIViewController(_ controller: BeckMapCanvasController<Key>, context: Context) {
        controller.update(
            key: key, camera: camera, renderScale: renderScale,
            renderOffset: renderOffset, overscan: overscan,
            canvasSize: canvasSize, colorScheme: colorScheme,
            displayScale: displayScale, renderer: renderer
        )
    }

    static func dismantleUIViewController(_ controller: BeckMapCanvasController<Key>, coordinator: ()) {
        controller.detachCamera()
    }
}

final class BeckMapCanvasController<Key: Equatable>: UIViewController {
    private var renderedKey: Key?
    private var renderedScale: CGFloat?
    private var renderedOffset: CGSize?
    private var renderedOverscan: CGFloat?
    private var renderedColorScheme: ColorScheme?
    private var renderedDisplayScale: CGFloat?
    private weak var camera: BeckMapLayerCamera?
    private let surface = UIView()

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        surface.backgroundColor = .clear
        surface.layer.anchorPoint = .zero
        surface.layer.position = .zero
        view.addSubview(surface)
    }

    func update(
        key: Key, camera: BeckMapLayerCamera, renderScale: CGFloat,
        renderOffset: CGSize, overscan: CGFloat, canvasSize: CGSize,
        colorScheme: ColorScheme, displayScale: CGFloat = 1,
        renderer: @escaping (inout GraphicsContext, CGSize) -> Void
    ) {
        loadViewIfNeeded()
        if self.camera !== camera {
            detachCamera()
            self.camera = camera
        }
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              displayScale.isFinite, displayScale > 0 else { return }
        let rebasesCamera = renderedScale != renderScale || renderedOffset != renderOffset
            || renderedOverscan != overscan || surface.bounds.size != canvasSize
        if renderedKey != key || rebasesCamera || renderedColorScheme != colorScheme
            || renderedDisplayScale != displayScale {
            // Avoid depending on a live hosted Canvas's layout and scheduled
            // presentation. Render the whole buffer independently of
            // window visibility, then publish pixels and their camera together.
            let raster = ImageRenderer(content: BeckMapCanvasDrawing(
                size: canvasSize, colorScheme: colorScheme, renderer: renderer
            ).environment(\.displayScale, displayScale))
            raster.proposedSize = ProposedViewSize(canvasSize)
            raster.scale = displayScale
            guard let image = raster.cgImage else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.bounds = CGRect(origin: .zero, size: canvasSize)
            surface.layer.contentsScale = displayScale
            surface.layer.contents = image
            renderedKey = key
            renderedScale = renderScale
            renderedOffset = renderOffset
            renderedOverscan = overscan
            renderedColorScheme = colorScheme
            renderedDisplayScale = displayScale
            camera.attach(
                layer: surface.layer, renderScale: renderScale,
                renderOffset: renderOffset, overscan: overscan
            )
            CATransaction.commit()
            return
        }
        camera.attach(
            layer: surface.layer, renderScale: renderScale,
            renderOffset: renderOffset, overscan: overscan
        )
    }

    func detachCamera() {
        camera?.detach(layer: surface.layer)
        camera = nil
    }
}

private struct BeckMapCanvasDrawing: View {
    let size: CGSize
    let colorScheme: ColorScheme
    let renderer: (inout GraphicsContext, CGSize) -> Void

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false, renderer: renderer)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
    }
}
