import SwiftUI

/// An original, compact "chomper" mark for the Station Chase easter egg.
/// It deliberately avoids branded character details while remaining legible
/// beside the map's other toolbar symbols.
struct StationChaseGlyph: View {
    var mouthAngle: Double = 34

    var body: some View {
        ChomperShape(mouthAngle: mouthAngle)
            .fill(Color(red: 1.0, green: 0.72, blue: 0.02))
            .overlay {
                ChomperShape(mouthAngle: mouthAngle)
                    .stroke(.primary.opacity(0.72), lineWidth: 1)
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

struct ChomperShape: Shape {
    var mouthAngle: Double

    var animatableData: Double {
        get { mouthAngle }
        set { mouthAngle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let diameter = min(rect.width, rect.height)
        guard diameter > 0 else { return Path() }

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = diameter / 2
        let opening = min(70, max(8, mouthAngle))
        let upper = Angle.degrees(opening)
        let lower = Angle.degrees(360 - opening)

        var path = Path()
        path.move(to: centre)
        path.addLine(to: point(on: centre, radius: radius, angle: upper))
        path.addArc(
            center: centre,
            radius: radius,
            startAngle: upper,
            endAngle: lower,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    private func point(
        on centre: CGPoint,
        radius: CGFloat,
        angle: Angle
    ) -> CGPoint {
        CGPoint(
            x: centre.x + CGFloat(cos(angle.radians)) * radius,
            y: centre.y + CGFloat(sin(angle.radians)) * radius
        )
    }
}
