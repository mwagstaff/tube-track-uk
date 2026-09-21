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

