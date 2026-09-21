import SwiftUI

public struct StatusSymbol: View {
    public let severity: Int
    public var size: CGFloat = 24

    public init(
        severity: Int,
        size: CGFloat = 24
    ) {
        self.severity = severity
        self.size = size
    }

    private var configuration: (String, Color) {
        switch severity {
        case 10: ("checkmark", .green)
        case 9: ("exclamationmark", .yellow)
        case 6, 1...5: ("exclamationmark.triangle.fill", .red)
        case 20: ("moon.zzz.fill", .indigo)
        default: ("info", .gray)
        }
    }

    public var body: some View {
        Image(systemName: configuration.0)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(configuration.1, in: .circle)
            .accessibilityHidden(true)
    }
}
