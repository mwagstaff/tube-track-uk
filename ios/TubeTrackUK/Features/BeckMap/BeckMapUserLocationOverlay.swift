import SwiftUI
import UIKit

/// Location and heading changes invalidate this small overlay, not the artwork.
struct BeckMapUserLocationOverlay: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(UserLocationProvider.self) private var locationProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let document: BeckMapDocument
    let camera: BeckMapLayerCamera

    var body: some View {
        if appState.selectedTab == .map,
           appState.mapPresentationMode == .beck,
           let graph = appState.graph,
           let location = locationProvider.location,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 1_000,
           MapLocationFocusPolicy.isWithinMapArea(location, in: graph),
           let point = SharedMapProjection.artworkPoint(
                for: location.coordinate, document: document, graph: graph
           ) {
            BeckMapLocationMarker(
                camera: camera, point: point,
                heading: locationProvider.heading, reduceMotion: reduceMotion
            )
        }
    }
}

private struct BeckMapLocationMarker: UIViewRepresentable {
    let camera: BeckMapLayerCamera
    let point: CGPoint
    let heading: Double?
    let reduceMotion: Bool

    func makeUIView(context: Context) -> LocationMarkerView { LocationMarkerView() }

    func updateUIView(_ view: LocationMarkerView, context: Context) {
        if view.camera !== camera {
            view.camera?.detach(layer: view.marker)
            view.camera = camera
        }
        camera.attach(layer: view.marker, at: point)
        view.update(heading: heading, pulses: !reduceMotion)
    }

    static func dismantleUIView(_ view: LocationMarkerView, coordinator: ()) {
        view.camera?.detach(layer: view.marker)
        view.pulse.removeAllAnimations()
    }
}

struct GeographicMapUserLocationMarker: UIViewRepresentable {
    @Environment(UserLocationProvider.self) private var locationProvider
    let mapHeading: Double
    let reduceMotion: Bool

    func makeUIView(context: Context) -> LocationMarkerView { LocationMarkerView() }

    func updateUIView(_ view: LocationMarkerView, context: Context) {
        view.update(
            heading: locationProvider.heading.map { $0 - mapHeading },
            pulses: !reduceMotion
        )
    }

    static func dismantleUIView(_ view: LocationMarkerView, coordinator: ()) {
        view.pulse.removeAllAnimations()
    }
}

final class LocationMarkerView: UIView {
    weak var camera: BeckMapLayerCamera?
    let marker = CALayer()
    let pulse = CAShapeLayer()
    private let direction = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(marker)

        let blue = UIColor.systemBlue.cgColor
        pulse.path = UIBezierPath(ovalIn: CGRect(x: -10, y: -10, width: 20, height: 20)).cgPath
        pulse.fillColor = blue
        pulse.opacity = 0.18
        marker.addSublayer(pulse)

        let beam = UIBezierPath()
        beam.move(to: .zero)
        beam.addArc(withCenter: .zero, radius: 38, startAngle: -.pi * 0.68,
                    endAngle: -.pi * 0.32, clockwise: true)
        beam.close()
        direction.path = beam.cgPath
        direction.fillColor = UIColor.systemBlue.withAlphaComponent(0.24).cgColor
        marker.addSublayer(direction)

        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: CGRect(x: -7, y: -7, width: 14, height: 14)).cgPath
        dot.fillColor = blue
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 2.5
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.2
        dot.shadowRadius = 3
        dot.shadowOffset = CGSize(width: 0, height: 1)
        marker.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard camera == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func update(heading: Double?, pulses: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        direction.isHidden = heading == nil
        direction.setAffineTransform(CGAffineTransform(rotationAngle: (heading ?? 0) * .pi / 180))
        CATransaction.commit()
        if pulses, pulse.animation(forKey: "locationPulse") == nil {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 2
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.add(group, forKey: "locationPulse")
        } else if !pulses {
            pulse.removeAllAnimations()
        }
    }
}
