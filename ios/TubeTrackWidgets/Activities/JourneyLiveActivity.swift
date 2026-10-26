import ActivityKit
import SwiftUI
import WidgetKit
import TubeTrackCore

struct JourneyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyActivityAttributes.self) { context in
            JourneyActivityContent(attributes: context.attributes, state: context.state, isStale: context.isStale)
            .activityBackgroundTint(DepartureBoardStyle.background)
            .activitySystemActionForegroundColor(DepartureBoardStyle.yellow)
            .widgetURL(DeepLink.journey(id: context.attributes.sessionID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(JourneyActivityAttributes.shortStationName(context.state.nextStop)).font(.headline).lineLimit(1).minimumScaleFactor(0.7) }
                DynamicIslandExpandedRegion(.trailing) { arrival(context.state.nextArrivalEpoch) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(JourneyActivityAttributes.shortStationName(context.state.destination)).lineLimit(1).minimumScaleFactor(0.7); Spacer(); arrival(context.state.finalArrivalEpoch) }
                        if context.isStale { Text("Updates delayed").font(.caption) }
                        else if let board = context.state.boardTitle {
                            HStack { Text(board).lineLimit(1).minimumScaleFactor(0.7); Spacer(); arrival(context.state.departures.first?.expectedAtEpoch) }.font(.system(.caption, design: .monospaced)).foregroundStyle(DepartureBoardStyle.yellow)
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
            .keylineTint(DepartureBoardStyle.yellow)
            .widgetURL(DeepLink.journey(id: context.attributes.sessionID).url)
        }
    }
    @ViewBuilder private func arrival(_ epoch: Int?) -> some View {
        if let epoch {
            Text(Date(timeIntervalSince1970: Double(epoch)), format: Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "Europe/London")!)).monospacedDigit()
        } else { Text("—").accessibilityLabel("Time unavailable") }
    }
}


struct JourneyActivityContent: View {
    let attributes: JourneyActivityAttributes
    let state: JourneyActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(attributes.summary(for: state))
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(attributes.summary(for: state))
            HStack(spacing: 12) {
                eta("Next", station: state.nextStop, epoch: state.nextArrivalEpoch)
                Spacer(minLength: 0)
                eta("Arrive", station: state.destination, epoch: state.finalArrivalEpoch)
            }
            .font(.caption)
            Rectangle().fill(DepartureBoardStyle.yellow.opacity(0.3)).frame(height: 1)
            if isStale {
                Text("Updates delayed · open journey").font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            } else if let title = state.boardTitle {
                Text(shortBoardTitle(title)).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                ForEach(Array(state.departures.prefix(2).enumerated()), id: \.element.id) { index, departure in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                        Text(JourneyActivityAttributes.shortStationName(departure.destination))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if departure.status == "cancelled" { Text("Cancelled") }
                            else { clock(departure.expectedAtEpoch) }
                        }
                        .font(.system(.caption2, design: .monospaced).bold())
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(DepartureBoardStyle.timeBackground, in: RoundedRectangle(cornerRadius: 4))
                    }.font(.system(.caption, design: .monospaced))
                }
                if state.departures.isEmpty { Text("No departures due").font(.caption) }
            }
        }
        .foregroundStyle(DepartureBoardStyle.yellow)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eta(_ label: String, station: String, epoch: Int?) -> some View {
        HStack(spacing: 4) {
            Text("\(label): \(JourneyActivityAttributes.shortStationName(station))")
                .lineLimit(1).minimumScaleFactor(0.7)
            clock(epoch).fixedSize()
        }
        .accessibilityLabel("Estimated arrival at \(station)")
        .accessibilityValue(epoch.map { Date(timeIntervalSince1970: Double($0)).formatted(DepartureBoardStyle.updateTime) } ?? "Time unavailable")
    }

    @ViewBuilder private func clock(_ epoch: Int?) -> some View {
        if let epoch { Text(Date(timeIntervalSince1970: Double(epoch)), format: DepartureBoardStyle.updateTime).monospacedDigit() }
        else { Text("—") }
    }

    private func shortBoardTitle(_ title: String) -> String {
        title.components(separatedBy: " → ").map(JourneyActivityAttributes.shortStationName).joined(separator: " → ")
    }
}

#if DEBUG
#Preview("Journey · compact board") {
    let state = try! JSONDecoder().decode(JourneyActivityAttributes.ContentState.self, from: Data("""
    {"phase":"waiting","legIndex":0,"headline":"Board at Elverson Road DLR Station",
     "nextStop":"Canary Wharf DLR Station","destination":"Stratford DLR Station",
     "nextArrivalEpoch":1792919640,"finalArrivalEpoch":1792920540,
     "boardTitle":"Elverson Road DLR Station → Canary Wharf DLR Station",
     "departures":[{"id":"1","destination":"Canary Wharf DLR Station","expectedAtEpoch":1792918800},
                   {"id":"2","destination":"Canary Wharf DLR Station","expectedAtEpoch":1792919400}],
     "updatedAtEpoch":1792918680,"staleAtEpoch":1792918770,"message":"","sequence":1}
    """.utf8))
    JourneyActivityContent(attributes: .init(sessionID: "preview", destination: state.destination,
        endsAtEpoch: 1792924140, origin: "Elverson Road DLR Station"), state: state, isStale: false)
        .frame(width: 350, height: 160)
        .background(DepartureBoardStyle.background, in: RoundedRectangle(cornerRadius: 24))
}
#endif
