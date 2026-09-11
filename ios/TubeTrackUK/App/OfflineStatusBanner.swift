import SwiftUI

enum OfflineStatusCopy {
    static func age(since date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 5 * 60 { return "a few minutes ago" }
        if elapsed < 60 * 60 { return "\(Int(elapsed / 60)) minutes ago" }
        if elapsed < 24 * 60 * 60 {
            let hours = Int(elapsed / 3_600)
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        let days = Int(elapsed / 86_400)
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }

    static func message(updatedAt: Date?, now: Date, isWorks: Bool) -> String {
        let data = isWorks ? "Works" : "Disruptions"
        guard let updatedAt else { return "Offline · No saved \(data.lowercased())" }
        return "Offline · \(data) updated \(age(since: updatedAt, now: now))"
    }
}

struct OfflineStatusBanner: View {
    let updatedAt: Date?
    let isWorks: Bool

    var body: some View {
        OfflineStatusMessage(updatedAt: updatedAt, isWorks: isWorks)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
    }
}

struct OfflineStatusMessage: View {
    let updatedAt: Date?
    let isWorks: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label(
                OfflineStatusCopy.message(
                    updatedAt: updatedAt,
                    now: context.date,
                    isWorks: isWorks
                ),
                systemImage: "wifi.slash"
            )
            .font(.appCaption(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("offlineStatusBanner")
        }
    }
}
