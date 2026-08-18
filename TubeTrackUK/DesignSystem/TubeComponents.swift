import SwiftUI

struct LineBadge: View {
    let lineID: TubeLineID
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.tubeLine(lineID))
                .frame(width: 10, height: 10)
                .overlay {
                    if lineID == .northern || lineID == .jubilee {
                        Circle().stroke(.white.opacity(0.75), lineWidth: 1)
                    }
                }
            if showsName {
                Text(lineID.displayName)
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lineID.displayName)
    }
}

struct FreshnessLabel: View {
    let date: Date?
    var cached = false

    var body: some View {
        if let date {
            HStack(spacing: 4) {
                if cached { Image(systemName: "clock.badge.exclamationmark") }
                Text(date, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(cached ? .orange : .secondary)
            .accessibilityLabel(cached ? "Saved data from \(date.formatted())" : "Updated \(date.formatted())")
        }
    }
}

struct StatusSymbol: View {
    let severity: Int
    var size: CGFloat = 24

    private var configuration: (String, Color) {
        switch severity {
        case 10: ("checkmark", .green)
        case 9: ("exclamationmark", .yellow)
        case 6, 1...5: ("exclamationmark.triangle.fill", .red)
        case 20: ("moon.zzz.fill", .indigo)
        default: ("info", .gray)
        }
    }

    var body: some View {
        Image(systemName: configuration.0)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(configuration.1, in: .circle)
            .accessibilityHidden(true)
    }
}

