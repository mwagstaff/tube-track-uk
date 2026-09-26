import SwiftUI
import TubeTrackCore
import WidgetKit

private struct WatchStatusEntry: TimelineEntry {
    let date: Date
    let state: WatchStatusState
}

private final class TimelineCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ value: Value) {
        completion(value)
    }
}

private enum WatchStatusTimeline {
    static func make(_ state: WatchStatusState) -> Timeline<WatchStatusEntry> {
        let next = WatchStatusRefreshPolicy.nextRequest(after: state.date)
        var entries = [WatchStatusEntry(date: state.date, state: state)]
        // If WidgetKit defers the requested reload, show the overdue marker
        // without waiting for another network request.
        if let warningDate = state.warningDate, warningDate > state.date {
            let warningEntryDate = max(warningDate, next)
            entries.append(WatchStatusEntry(
                date: warningEntryDate,
                state: WatchStatusState(
                    date: warningEntryDate, rows: state.rows, updatedAt: state.updatedAt,
                    isCached: state.isCached, failed: state.failed
                )
            ))
        }
        return Timeline(entries: entries, policy: .after(next))
    }
}

private struct WatchRectangularProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        let state = WatchStatusData.sample(lineIDs: [.central, .circle, .victoria])
        return WatchStatusEntry(date: state.date, state: state)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        let lineIDs = WatchWidgetPreferences.rectangularLines
        if context.isPreview {
            let state = WatchStatusData.sample(lineIDs: lineIDs)
            completion(WatchStatusEntry(date: state.date, state: state))
        } else {
            let finish = TimelineCompletion(completion)
            Task {
                let state = await WatchStatusData.load(lineIDs: lineIDs)
                finish(WatchStatusEntry(date: state.date, state: state))
            }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        let lineIDs = WatchWidgetPreferences.rectangularLines
        let finish = TimelineCompletion(completion)
        Task {
            finish(WatchStatusTimeline.make(await WatchStatusData.load(lineIDs: lineIDs)))
        }
    }
}

private struct WatchCircularProvider: TimelineProvider {
    let slot: WatchCircularSlot

    func placeholder(in context: Context) -> WatchStatusEntry {
        let state = WatchStatusData.sample(lineIDs: [slot.defaultLine])
        return WatchStatusEntry(date: state.date, state: state)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        let lineIDs = [WatchWidgetPreferences.circularLine(for: slot)]
        if context.isPreview {
            let state = WatchStatusData.sample(lineIDs: lineIDs)
            completion(WatchStatusEntry(date: state.date, state: state))
        } else {
            let finish = TimelineCompletion(completion)
            Task {
                let state = await WatchStatusData.load(lineIDs: lineIDs)
                finish(WatchStatusEntry(date: state.date, state: state))
            }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        let lineIDs = [WatchWidgetPreferences.circularLine(for: slot)]
        let finish = TimelineCompletion(completion)
        Task {
            finish(WatchStatusTimeline.make(await WatchStatusData.load(lineIDs: lineIDs)))
        }
    }
}

struct WatchRectangularLineStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "WatchRectangularLineStatus",
            provider: WatchRectangularProvider()
        ) { entry in
            WatchRectangularStatusView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Line Status")
        .description("Choose up to three lines in the Watch app.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WatchCircleOneWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "WatchCircularLineStatus",
            provider: WatchCircularProvider(slot: .one)
        ) { entry in
            WatchCircularStatusView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Circle 1")
        .description("Choose the line for Circle 1 in the Watch app.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct WatchCircleTwoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "WatchCircularLineStatus2",
            provider: WatchCircularProvider(slot: .two)
        ) { entry in
            WatchCircularStatusView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Circle 2")
        .description("Choose the line for Circle 2 in the Watch app.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct WatchCircleThreeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "WatchCircularLineStatus3",
            provider: WatchCircularProvider(slot: .three)
        ) { entry in
            WatchCircularStatusView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Circle 3")
        .description("Choose the line for Circle 3 in the Watch app.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct WatchRectangularStatusView: View {
    let entry: WatchStatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.state.rows.isEmpty {
                Label(entry.state.failed ? "Unavailable" : "Choose lines", systemImage: "wifi.slash")
                    .font(.caption)
            } else {
                ForEach(entry.state.rows.prefix(3)) { row in
                    HStack(spacing: 4) {
                        Text(row.lineID.watchShortName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 1)
                        WatchConditionIcon(condition: row.condition, state: entry.state, size: 15)
                    }
                    .frame(maxWidth: .infinity, minHeight: 17)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.lineID.displayName), \(row.condition.accessibilityDescription), \(freshnessDescription)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(statusURL)
    }

    private var freshnessDescription: String {
        entry.state.accessibilityFreshness
    }

    private var statusURL: URL {
        var components = URLComponents(url: DeepLink.status.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lines", value: entry.state.rows.map { $0.lineID.rawValue }.joined(separator: ","))
        ]
        return components.url ?? DeepLink.status.url
    }
}

private struct WatchCircularStatusView: View {
    let entry: WatchStatusEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let row = entry.state.rows.first {
                VStack(spacing: 0) {
                    Text(row.lineID.shortCode)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    WatchConditionIcon(condition: row.condition, state: entry.state, size: 19)
                }
                .padding(3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.lineID.displayName), \(row.condition.accessibilityDescription), \(entry.state.accessibilityFreshness)")
            } else {
                Image(systemName: "wifi.slash")
                    .font(.title3)
                    .accessibilityLabel("Line status unavailable")
            }
        }
        .widgetURL(entry.state.rows.first.map { DeepLink.line($0.lineID).url } ?? DeepLink.status.url)
    }
}

private struct WatchConditionIcon: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let condition: LineServiceCondition
    let state: WatchStatusState
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: condition.symbolName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(condition.tint) : AnyShapeStyle(.primary))
                .widgetAccentable()
            if state.showsAgeWarning {
                Image(systemName: "clock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.primary)
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: size + 5, height: size + 3)
        .accessibilityHidden(true)
    }
}

@main
struct TubeTrackWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchRectangularLineStatusWidget()
        WatchCircleOneWidget()
        WatchCircleTwoWidget()
        WatchCircleThreeWidget()
    }
}

#Preview("Three lines", as: .accessoryRectangular) {
    WatchRectangularLineStatusWidget()
} timeline: {
    let state = WatchStatusData.sample(lineIDs: [.hammersmithCity, .elizabeth, .victoria])
    WatchStatusEntry(date: state.date, state: state)
}

#Preview("One line", as: .accessoryCircular) {
    WatchCircleOneWidget()
} timeline: {
    let state = WatchStatusData.sample(lineIDs: [.central])
    WatchStatusEntry(date: state.date, state: state)
}
