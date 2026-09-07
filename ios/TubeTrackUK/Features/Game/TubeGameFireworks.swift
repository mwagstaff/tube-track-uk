import SwiftUI

/// A bounded celebration, independent of the stopped game clock. No timers or
/// particle simulation survive removal of the results view.
struct TubeGameFireworks: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        Canvas { context, size in
            guard elapsed < 30 else { return }
            // Start with a burst already opening, rather than an almost invisible rocket.
            let time = reduceMotion ? 2.3 : elapsed + 1
            context.blendMode = .plusLighter
            let fade = min(1, (30 - elapsed) / 2)
            for shell in 0..<42 {
                let age = time - Double(shell) * 0.72
                guard age >= 0, age < 3.8 else { continue }
                drawShell(shell, age: age, fade: fade, context: &context, size: size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // An explicit clock keeps ticking even inside a paused TimelineView.
            // Cancel on disappearance/inactivity and preserve the remaining show.
            let clock = ContinuousClock()
            let start = clock.now
            let previousElapsed = elapsed
            do {
                while elapsed < 30 {
                    try await Task.sleep(for: .milliseconds(33))
                    let duration = start.duration(to: clock.now).components
                    elapsed = min(30, previousElapsed + Double(duration.seconds)
                        + Double(duration.attoseconds) / 1e18)
                }
            } catch { return }
        }
    }

    private func drawShell(
        _ seed: Int, age: Double, fade: Double,
        context: inout GraphicsContext, size: CGSize
    ) {
        let origin = CGPoint(
            x: size.width * (0.08 + random(seed * 7 + 1) * 0.84),
            y: size.height * (0.08 + random(seed * 7 + 2) * 0.66)
        )
        let colours: [Color] = [.yellow, .cyan, .pink, .orange, .mint, .purple]
        let colour = colours[seed % colours.count]
        if age < 0.65 {
            let progress = age / 0.65
            let y = size.height + (origin.y - size.height) * progress
            var trail = Path()
            trail.move(to: CGPoint(x: origin.x, y: y + 44))
            trail.addLine(to: CGPoint(x: origin.x, y: y))
            context.stroke(trail, with: .linearGradient(
                Gradient(colors: [.clear, .yellow.opacity(0.8 * fade)]),
                startPoint: CGPoint(x: origin.x, y: y + 44), endPoint: CGPoint(x: origin.x, y: y)
            ), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            return
        }
        let burstAge = age - 0.65
        let spread = min(size.width * 0.42, 230.0)
        let alpha = pow(max(0, 1 - burstAge / 3.15), 1.5) * fade
        for spark in 0..<90 {
            let angle = Double(spark) * .pi * 2 / 90
            let speed = spread * (0.48 + random(seed * 101 + spark) * 0.52)
            let radius = speed * (1 - exp(-burstAge * 1.5))
            let tailRadius = speed * (1 - exp(-max(0, burstAge - 0.12) * 1.5))
            let gravity = burstAge * burstAge * 22
            let point = CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius + gravity)
            let tail = CGPoint(x: origin.x + cos(angle) * tailRadius, y: origin.y + sin(angle) * tailRadius + gravity - 5)
            var path = Path()
            path.move(to: tail)
            path.addLine(to: point)
            context.stroke(path, with: .color(colour.opacity(alpha * 0.18)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            context.stroke(path, with: .color(colour.opacity(alpha)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let sparkle = 0.65 + 0.35 * sin(burstAge * 9 + Double(spark))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)), with: .color(.white.opacity(alpha * sparkle)))
        }
    }

    private func random(_ seed: Int) -> Double {
        let value = sin(Double(seed + 1) * 127.1) * 43758.5453
        return value - floor(value)
    }
}
