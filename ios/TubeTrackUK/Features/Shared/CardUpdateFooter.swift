import SwiftUI

struct CardUpdateText: Equatable {
    let text: String
    let warning: String?
    let symbol: String

    static func resolve(updatedAt: Date?, now: Date, offline: Bool, stale: Bool,
                        staleAfter: TimeInterval) -> Self {
        let expired = updatedAt.map { now.timeIntervalSince($0) > staleAfter } ?? false
        let warning = offline ? "Offline · Live updates unavailable"
            : stale || expired ? "Updates delayed · Information may be out of date" : nil
        guard let updatedAt else {
            return .init(text: "Waiting for the first update", warning: warning,
                         symbol: offline ? "wifi.slash" : "exclamationmark.icloud")
        }
        let age = max(0, now.timeIntervalSince(updatedAt))
        let relative: String
        if age < 60 { relative = "just now" }
        else if age < 3600 {
            let minutes = Int(age / 60)
            relative = "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if age < 86400 {
            let hours = Int(age / 3600)
            relative = "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(age / 86400)
            relative = "\(days) day\(days == 1 ? "" : "s") ago"
        }
        let format = LondonRailDate.calendar.isDate(updatedAt, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return .init(text: "Last updated \(relative), at \(LondonRailDate.formatted(updatedAt, dateFormat: format))",
                     warning: warning, symbol: offline ? "wifi.slash" : "exclamationmark.icloud")
    }
}

/// Shared bottom-of-card source age. Receiving a cached response never resets it.
struct CardUpdateFooter: View {
    let updatedAt: Date?
    let isOffline: Bool
    let isStale: Bool
    var staleAfter: TimeInterval = 120
    var validUntil: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let presentation = CardUpdateText.resolve(updatedAt: updatedAt, now: timeline.date,
                offline: isOffline, stale: isStale || validUntil.map { timeline.date > $0 } == true, staleAfter: staleAfter)
            VStack(alignment: .leading, spacing: 4) {
                if let warning = presentation.warning {
                    Label(warning, systemImage: presentation.symbol)
                        .foregroundStyle(.orange)
                }
                Text(presentation.text).foregroundStyle(.secondary)
            }
            .font(.appCaption())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
