import ActivityKit
import SwiftUI
import WidgetKit
import TubeTrackCore

struct JourneyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.headline).font(.headline)
                HStack {
                    Text(context.state.nextStop).lineLimit(1)
                    Spacer()
                    arrival(context.state.nextArrivalEpoch)
                }
                HStack {
                    Text(context.state.destination).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    arrival(context.state.finalArrivalEpoch)
                }
                if context.isStale {
                    Label("Updates delayed · open journey", systemImage: "clock.badge.exclamationmark").font(.caption)
                } else if let title = context.state.boardTitle {
                    Text(title).font(.caption.bold()).lineLimit(1)
                    ForEach(context.state.departures.prefix(2)) { departure in
                        HStack {
                            Text(departure.destination).lineLimit(1)
                            Spacer()
                            if departure.status == "cancelled" { Text("Cancelled") }
                            else { arrival(departure.expectedAtEpoch) }
                        }.font(.caption)
                    }
                }
                Text("Estimated arrival times").font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .widgetURL(DeepLink.journey(id: context.attributes.sessionID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.state.nextStop).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) { arrival(context.state.nextArrivalEpoch) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(context.state.destination); Spacer(); arrival(context.state.finalArrivalEpoch) }
                        if context.isStale { Text("Updates delayed").font(.caption) }
                        else if let board = context.state.boardTitle {
                            HStack { Text(board).lineLimit(1); Spacer(); arrival(context.state.departures.first?.expectedAtEpoch) }.font(.caption)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : "tram.fill")
            } compactTrailing: {
                arrival(context.state.nextArrivalEpoch).font(.caption)
            } minimal: {
                Image(systemName: "tram.fill")
            }
            .widgetURL(DeepLink.journey(id: context.attributes.sessionID).url)
        }
    }
    @ViewBuilder private func arrival(_ epoch: Int?) -> some View {
        if let epoch {
            Text(Date(timeIntervalSince1970: Double(epoch)), format: Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "Europe/London")!)).monospacedDigit()
        } else { Text("—").accessibilityLabel("Time unavailable") }
    }
}
