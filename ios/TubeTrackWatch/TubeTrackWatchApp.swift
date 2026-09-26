import SwiftUI
import TubeTrackCore
import WidgetKit

@main
struct TubeTrackWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchStatusScreen()
        }
    }
}

private enum WatchRoute: Hashable {
    case settings
    case otherLines
    case line(TubeLineID)
}

private struct WatchStatusScreen: View {
    @State private var status: WatchStatusState?
    @State private var selectedLines = WatchWidgetPreferences.selectedLines
    @State private var path: [WatchRoute] = []

    private var otherLines: [TubeLineID] {
        let selected = Set(selectedLines)
        return TubeLineID.widgetDisplayOrder
            .filter { !selected.contains($0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: WatchRoute.settings) {
                    Label("Choose widget lines", systemImage: "slider.horizontal.3")
                }
                Section("Widget lines") {
                    ForEach(selectedLines) { lineID in
                        NavigationLink(value: WatchRoute.line(lineID)) {
                            WatchLineStatusRow(
                                lineID: lineID,
                                row: status?.row(for: lineID),
                                isLoading: status == nil
                            )
                        }
                    }
                }
                NavigationLink(value: WatchRoute.otherLines) {
                    Label("All other lines", systemImage: "list.bullet")
                }
                if status == nil {
                    ProgressView("Loading status")
                } else if let status, status.rows.isEmpty {
                    Label("Status unavailable", systemImage: "wifi.slash")
                }
                if let status, status.freshness.isDegraded || status.failed {
                    Text(status.freshness.summary(at: .now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Line status")
            .toolbar {
                Button {
                    Task { await refresh(reloadWidgets: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh line status")
            }
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .settings:
                    WatchWidgetSettingsScreen {
                        selectedLines = WatchWidgetPreferences.selectedLines
                    }
                case .otherLines:
                    WatchOtherLinesScreen(lines: otherLines, status: status)
                case let .line(lineID):
                    WatchLineDetail(lineID: lineID, row: status?.row(for: lineID), status: status)
                }
            }
        }
        .onAppear { selectedLines = WatchWidgetPreferences.selectedLines }
        .task { await refresh() }
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            switch link {
            case .status:
                path = []
            case let .line(lineID):
                path = [.line(lineID)]
            case .station:
                break
            }
            Task { await refresh() }
        }
    }

    private func refresh(reloadWidgets: Bool = false) async {
        let loaded = await WatchStatusData.load(lineIDs: TubeLineID.widgetDisplayOrder)
        guard !Task.isCancelled else { return }
        status = loaded
        if reloadWidgets {
            WidgetCenter.shared.reloadTimelines(ofKind: "WatchRectangularLineStatus")
            for slot in WatchCircularSlot.allCases {
                WidgetCenter.shared.reloadTimelines(ofKind: slot.kind)
            }
        }
    }
}

private struct WatchLineStatusRow: View {
    let lineID: TubeLineID
    let row: LineStatusSummary?
    let isLoading: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(Color.tubeLine(lineID))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(lineID.displayName)
                .lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: row?.condition.symbolName ?? (isLoading ? "arrow.clockwise" : "wifi.slash"))
                .foregroundStyle(row?.condition.tint ?? Color.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lineID.displayName), \(row?.condition.accessibilityDescription ?? (isLoading ? "Loading status" : "Status unavailable"))")
    }
}

private struct WatchOtherLinesScreen: View {
    let lines: [TubeLineID]
    let status: WatchStatusState?

    var body: some View {
        List {
            ForEach(lines) { lineID in
                NavigationLink(value: WatchRoute.line(lineID)) {
                    WatchLineStatusRow(
                        lineID: lineID,
                        row: status?.row(for: lineID),
                        isLoading: status == nil
                    )
                }
            }
            if let status, status.freshness.isDegraded || status.failed {
                Text(status.freshness.summary(at: .now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("All other lines")
    }
}

private struct WatchWidgetSettingsScreen: View {
    let onSelectionChange: () -> Void
    @State private var rectangular = WatchWidgetPreferences.rectangularLines
    @State private var circularLines = WatchCircularSlot.allCases.map {
        WatchWidgetPreferences.circularLine(for: $0)
    }

    var body: some View {
        List {
            Section("Circular") {
                ForEach(WatchCircularSlot.allCases) { slot in
                    Picker(slot.title, selection: circularBinding(for: slot)) {
                        ForEach(TubeLineID.widgetDisplayOrder) { line in
                            Text(line.displayName).tag(line)
                        }
                    }
                }
            }
            Section("Rectangular · up to 3") {
                ForEach(TubeLineID.widgetDisplayOrder) { line in
                    Button {
                        if rectangular.contains(line) {
                            guard rectangular.count > 1 else { return }
                            rectangular.removeAll { $0 == line }
                        } else if rectangular.count < 3 {
                            rectangular.append(line)
                        }
                        WatchWidgetPreferences.setRectangularLines(rectangular)
                        onSelectionChange()
                        WidgetCenter.shared.reloadTimelines(ofKind: "WatchRectangularLineStatus")
                    } label: {
                        HStack {
                            Text(line.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if rectangular.contains(line) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(!rectangular.contains(line) && rectangular.count == 3)
                    .accessibilityLabel("\(line.displayName), \(rectangular.contains(line) ? "selected" : "not selected")")
                }
            }
        }
        .navigationTitle("Widget lines")
    }

    private func circularBinding(for slot: WatchCircularSlot) -> Binding<TubeLineID> {
        let index = slot.rawValue - 1
        return Binding(
            get: { circularLines[index] },
            set: { line in
                circularLines[index] = line
                WatchWidgetPreferences.setCircularLine(line, for: slot)
                onSelectionChange()
                WidgetCenter.shared.reloadTimelines(ofKind: slot.kind)
            }
        )
    }
}

private struct WatchLineDetail: View {
    let lineID: TubeLineID
    let row: LineStatusSummary?
    let status: WatchStatusState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let row {
                    Label(row.condition.headline, systemImage: row.condition.symbolName)
                        .font(.headline)
                        .foregroundStyle(row.condition.tint)
                    if let reason = row.reason {
                        Text(reason)
                            .font(.body)
                    }
                } else {
                    Label("Status unavailable", systemImage: "wifi.slash")
                }
                if let status {
                    Text(status.freshness.summary(at: .now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(lineID.displayName)
    }
}
