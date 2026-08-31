import SwiftUI
import UIKit

extension Color {
    static let departureAccent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return .systemBlue
        }
        return UIColor(red: 0.04, green: 0.17, blue: 0.43, alpha: 1)
    })
}

struct TubeLineDot: View {
    let lineID: TubeLineID
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color.tubeLine(lineID))
            .frame(width: size, height: size)
            .overlay {
                if lineID == .northern || lineID == .jubilee {
                    Circle().stroke(.white.opacity(0.75), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

struct LineBadge: View {
    let lineID: TubeLineID
    var showsName = true
    var activeTrainCount: Int? = nil

    private var displayLabel: String {
        guard let activeTrainCount else { return lineID.displayName }
        return "\(lineID.displayName) (\(activeTrainCount))"
    }

    var body: some View {
        HStack(spacing: 6) {
            TubeLineDot(lineID: lineID)
            if showsName {
                Text(displayLabel)
                    .lineLimit(1)
            }
        }
        .font(.appCaption(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            activeTrainCount.map { "\(lineID.displayName), \($0) active trains" }
                ?? lineID.displayName
        )
    }
}

struct FreshnessLabel: View {
    let date: Date?
    var cached = false
    var staleAfter: TimeInterval = 120

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let freshness = RailDataFreshness.evaluate(
                    updatedAt: date,
                    now: context.date,
                    cached: cached,
                    staleAfter: staleAfter
                )

                Group {
                    if freshness == .stale {
                        Label("Data may be stale", systemImage: "clock.badge.exclamationmark")
                    } else {
                        Text("Updated just now")
                    }
                }
                .font(.appCaption2())
                .foregroundStyle(freshness == .stale ? .orange : .secondary)
                .accessibilityLabel(
                    freshness == .stale
                        ? "Data may be stale. Last updated \(date.formatted())"
                        : "Updated just now"
                )
            }
        }
    }
}

enum RailDataFreshness: Equatable {
    case current
    case stale

    static func evaluate(
        updatedAt: Date,
        now: Date,
        cached: Bool,
        staleAfter: TimeInterval
    ) -> RailDataFreshness {
        guard !cached, now.timeIntervalSince(updatedAt) < staleAfter else {
            return .stale
        }
        return .current
    }
}

enum LiveStatusStaleness {
    static let threshold: TimeInterval = 30

    static func isStale(updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) >= threshold
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
