import SwiftUI

enum LiveTrainMarkerRenderer {
    static func draw(
        presentation: LiveTrainServicePresentation,
        lineID: TubeLineID,
        context: inout GraphicsContext,
        in rect: CGRect
    ) {
        guard presentation == .lineClosed else {
            let markerImage = context.resolve(Image(lineID.liveTrainMarkerAssetName))
            context.draw(markerImage, in: rect)
            return
        }

        let badge = Path(ellipseIn: rect)
        context.fill(badge, with: .color(.white))
        context.stroke(badge, with: .color(.tubeBlue.opacity(0.72)), lineWidth: 1.25)

        let ghostRect = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.16)
        context.fill(ghostPath(in: ghostRect), with: .color(.tubeBlue))

        let eyeDiameter = max(1.5, ghostRect.width * 0.16)
        for horizontalPosition in [0.34, 0.66] {
            let eye = CGRect(
                x: ghostRect.minX + ghostRect.width * horizontalPosition - eyeDiameter / 2,
                y: ghostRect.minY + ghostRect.height * 0.38 - eyeDiameter / 2,
                width: eyeDiameter,
                height: eyeDiameter
            )
            context.fill(Path(ellipseIn: eye), with: .color(.white))
        }
    }

    private static func ghostPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.minX, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.17, y: rect.maxY - rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.33, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.33, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.17, y: rect.maxY - rect.height * 0.14))
        path.closeSubpath()
        return path
    }
}
