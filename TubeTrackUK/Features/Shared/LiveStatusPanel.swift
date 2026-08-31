import SwiftUI
import UIKit

struct LiveStatusDock: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var expanded: Bool

    private var summary: (symbol: String, color: Color, title: String, detail: String?) {
        if !appState.isViewingLiveStatus {
            let date = LondonRailDate.formatted(
                appState.selectedDisruptionDate,
                dateFormat: "EEE d MMM"
            )
            if appState.isRefreshingWorks && appState.engineeringWorks.isEmpty {
                return ("arrow.trianglehead.2.clockwise.rotate.90", .blue, "Loading planned work", date)
            }
            if let error = appState.worksError, appState.engineeringWorks.isEmpty {
                return ("wifi.slash", .orange, "Planned work unavailable", error)
            }
            let count = appState.currentIssueCount
            if count > 0 {
                return (
                    "wrench.and.screwdriver.fill",
                    .orange,
                    "\(count) planned work\(count == 1 ? "" : "s")",
                    date
                )
            }
            if appState.plannedWorksForSelectedDate.isEmpty {
                return ("checkmark.circle.fill", .green, "No planned work reported", date)
            }
            if appState.selectedDisruptionTimeWindows.isEmpty {
                return ("clock.badge.questionmark", .blue, "Choose a time window", date)
            }
            return ("clock.badge.xmark", .secondary, "No work in selected times", date)
        }
        if appState.isRefreshingDisruptionData && appState.statuses.isEmpty {
            return ("arrow.trianglehead.2.clockwise.rotate.90", .blue, "Updating network status", "Fetching live TfL data")
        }
        if let error = appState.disruptionDataError, appState.statuses.isEmpty {
            return ("wifi.slash", .orange, "Live status unavailable", error)
        }
        if appState.currentIssueCount > 0 {
            let count = appState.currentIssueCount
            return ("exclamationmark.triangle.fill", .red, "\(count) issue\(count == 1 ? "" : "s")", nil)
        }
        let overnight = !appState.statuses.isEmpty && appState.statuses.allSatisfy {
            $0.lineStatuses.allSatisfy(\.isOvernightClosure)
        }
        if overnight {
            return ("moon.zzz.fill", .indigo, "Rail services closed", "Service resumes later this morning")
        }
        return ("checkmark.circle.fill", .green, "Good service", "\(appState.goodServiceLineCount) of \(TubeLineID.allCases.count) lines reporting normally")
    }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.18)) {
                expanded.toggle()
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                regularLayout
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .zIndex(1)
        .accessibilityHint(expanded ? "Collapses live status" : "Expands live status")
    }

    private var regularLayout: some View {
        HStack(spacing: 12) {
            statusIcon
            statusText(lineLimit: 1)
            Spacer()
            disclosureIcon
        }
        .padding(.horizontal, 14)
        .frame(
            maxWidth: .infinity,
            minHeight: MapDockMetrics.controlSize,
            maxHeight: MapDockMetrics.controlSize
        )
        .contentShape(.interaction, Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 44, height: 44)

            statusText(lineLimit: 2)

            Spacer(minLength: 4)
            disclosureIcon
                .frame(width: 44, height: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .contentShape(.interaction, Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private var statusIcon: some View {
        Image(systemName: summary.symbol)
            .font(.headline)
            .foregroundStyle(summary.color)
            .symbolEffect(.pulse, isActive: appState.isRefreshingStatus)
    }

    private func statusText(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
            }
        }
    }

    private var disclosureIcon: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.up")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

struct MapStatusDock: View {
    @Binding var expanded: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                LiveStatusDock(expanded: $expanded)
                MapActionButtons()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
    }
}

struct DisruptionTimeFilterBar: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    buttons
                }
                .scrollIndicators(.hidden)
            } else {
                buttons
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(DisruptionTimeWindow.allCases) { window in
                timeButton(for: window)
            }
        }
    }

    private func timeButton(for window: DisruptionTimeWindow) -> some View {
        let selected = appState.selectedDisruptionTimeWindows.contains(window)
        let count = appState.plannedWorkCount(in: window)

        return Button {
            withAnimation(.smooth(duration: 0.2)) {
                appState.toggleDisruptionTimeWindow(window)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark" : window.symbol)
                    .font(.caption.weight(.bold))
                    .frame(width: 14)
                Text(window.title)
                    .font(.caption.weight(.semibold))
                Text(count, format: .number)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(
                        selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.09),
                        in: .capsule
                    )
            }
            .foregroundStyle(selected ? Color.white : Color(uiColor: .label))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected
                ? .regular.tint(Color.tubeBlue).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("\(window.title), \(window.rangeTitle), \(count) planned work\(count == 1 ? "" : "s")")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected ? "Double tap to hide this time window" : "Double tap to show this time window")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DisruptionDateMenu: View {
    @Environment(TubeAppState.self) private var appState
    @State private var showsCustomDatePicker = false
    @State private var draftDate = Date.now
    var compact = false

    private var today: Date {
        DisruptionDateSelection.today.date()
    }

    private var saturday: Date {
        DisruptionDateSelection.thisSaturday.date()
    }

    private var sunday: Date {
        DisruptionDateSelection.thisSunday.date()
    }

    var body: some View {
        Menu {
            quickDateButton(
                title: "Today",
                subtitle: LondonRailDate.formatted(today, dateFormat: "d MMM"),
                symbol: "sun.max",
                selection: .today
            )
            quickDateButton(
                title: "This Saturday",
                subtitle: LondonRailDate.formatted(saturday, dateFormat: "d MMM"),
                symbol: "calendar",
                selection: .thisSaturday
            )
            quickDateButton(
                title: "This Sunday",
                subtitle: LondonRailDate.formatted(sunday, dateFormat: "d MMM"),
                symbol: "calendar",
                selection: .thisSunday
            )

            Divider()

            Button {
                draftDate = appState.selectedDisruptionDate
                showsCustomDatePicker = true
            } label: {
                Label("Choose Date…", systemImage: "calendar")
                Text("Next 60 days")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .foregroundStyle(Color(uiColor: .label))
                if !compact {
                    Text(selectionTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(Color(uiColor: .label))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
            .padding(.horizontal, compact ? 0 : 12)
            .frame(width: compact ? 44 : nil)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.glass)
        .menuOrder(.fixed)
        .accessibilityLabel("Disruption date")
        .accessibilityValue(accessibilityDate)
        .sheet(isPresented: $showsCustomDatePicker) {
            customDatePicker
        }
    }

    private func quickDateButton(
        title: String,
        subtitle: String,
        symbol: String,
        selection: DisruptionDateSelection
    ) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) {
                appState.setDisruptionDateSelection(selection)
            }
        } label: {
            Label(
                title,
                systemImage: appState.disruptionDateSelection == selection
                    ? "checkmark"
                    : symbol
            )
            Text(subtitle)
        }
    }

    private var selectionTitle: String {
        switch appState.disruptionDateSelection {
        case .today:
            return "Today"
        case .thisSaturday:
            return "This Saturday"
        case .thisSunday:
            return "This Sunday"
        case let .custom(date):
            return LondonRailDate.formatted(date, dateFormat: "EEE d MMM")
        }
    }

    private var accessibilityDate: String {
        LondonRailDate.formatted(
            appState.selectedDisruptionDate,
            dateFormat: "EEEE d MMMM yyyy"
        )
    }

    private var customDatePicker: some View {
        NavigationStack {
            DatePicker(
                "Disruption date",
                selection: $draftDate,
                in: today...appState.latestSelectableDisruptionDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Choose a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsCustomDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        appState.setDisruptionDateSelection(.custom(draftDate))
                        showsCustomDatePicker = false
                    }
                }
            }
        }
        .environment(\.calendar, LondonRailDate.calendar)
        .environment(\.timeZone, LondonRailDate.timeZone)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct LiveStatusPanel: View {
    @Environment(TubeAppState.self) private var appState
    @Binding var expanded: Bool

    var body: some View {
        GlassPanel {
            VStack(spacing: 12) {
                HStack {
                    Text(appState.isViewingLiveStatus ? "Live Status" : "Planned Work")
                        .font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        withAnimation(.spring(duration: 0.35)) { expanded = false }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        appState.isViewingLiveStatus
                            ? "Collapses live status"
                            : "Collapses planned work"
                    )
                }

                if appState.isViewingLiveStatus {
                    StaleLiveStatusNotice(updatedAt: appState.statusUpdatedAt)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            DisruptionDateMenu()
                            Spacer(minLength: 8)
                            DisruptionCategoryFilterMenu()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            DisruptionDateMenu()
                            DisruptionCategoryFilterMenu()
                        }
                    }
                    if !appState.isViewingLiveStatus {
                        DisruptionTimeFilterBar()
                    }
                }

                if appState.isViewingLiveStatus {
                    liveDisruptionsContent
                } else {
                    plannedWorksContent
                }
            }
        }
    }

    @ViewBuilder
    private var liveDisruptionsContent: some View {
        if appState.isRefreshingStatus && appState.statuses.isEmpty {
            ProgressView("Updating network status…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if appState.disruptions.isEmpty {
            noDisruptionsView
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(appState.disruptions) { disruption in
                        DisruptionRow(disruption: disruption) {
                            withAnimation(.spring(duration: 0.35)) { expanded = false }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 280)
        }
    }

    @ViewBuilder
    private var plannedWorksContent: some View {
        if appState.isRefreshingWorks && appState.engineeringWorks.isEmpty {
            ProgressView("Loading planned work…")
                .frame(maxWidth: .infinity, minHeight: 170)
        } else if appState.selectedEngineeringWorks.isEmpty {
            let date = LondonRailDate.formatted(
                appState.selectedDisruptionDate,
                dateFormat: "EEEE d MMMM"
            )
            let hasWorkOnDate = !appState.plannedWorksForSelectedDate.isEmpty
            let hasSelectedWindows = !appState.selectedDisruptionTimeWindows.isEmpty
            let emptyState: (title: String, symbol: String, description: String) = {
                if let error = appState.worksError {
                    return ("Planned work unavailable", "wifi.slash", error)
                }
                if !hasSelectedWindows {
                    return (
                        "Choose a time window",
                        "clock.badge.questionmark",
                        "Select AM, PM, or Overnight to show planned work on \(date)."
                    )
                }
                if hasWorkOnDate {
                    return (
                        "No work in selected times",
                        "clock.badge.xmark",
                        "TfL has planned work on \(date), but none overlaps the selected time windows."
                    )
                }
                return (
                    "No planned work reported",
                    "checkmark.circle.fill",
                    "TfL has no planned rail work listed for \(date)."
                )
            }()
            ContentUnavailableView(
                emptyState.title,
                systemImage: emptyState.symbol,
                description: Text(emptyState.description)
            )
            .frame(height: 170)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(appState.selectedEngineeringWorks) { work in
                        PlannedWorkRow(work: work) {
                            withAnimation(.spring(duration: 0.35)) { expanded = false }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 300)
        }
    }

    @ViewBuilder
    private var noDisruptionsView: some View {
        let overnightStatuses = appState.statuses.flatMap { line in
            line.lineStatuses.filter(\.isOvernightClosure).map { (line.id, $0) }
        }
        if !overnightStatuses.isEmpty {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(overnightStatuses.enumerated()), id: \.offset) { _, entry in
                        let (lineID, status) = entry
                        HStack {
                            LineBadge(lineID: lineID)
                            Spacer()
                            Text(status.statusSeverityDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
        } else {
            ContentUnavailableView(
                "Good service",
                systemImage: "checkmark.circle.fill",
                description: Text("No live rail disruptions are currently reported.")
            )
            .frame(height: 160)
        }
    }
}

private struct StaleLiveStatusNotice: View {
    let updatedAt: Date?

    var body: some View {
        if let updatedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if LiveStatusStaleness.isStale(
                    updatedAt: updatedAt,
                    now: context.date
                ) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text("Live disruption data is stale. Retrying…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 4)

                        ProgressView()
                            .controlSize(.small)
                            .tint(.orange)
                            .accessibilityLabel("Retrying")
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct DisruptionCategoryFilterMenu: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        Menu {
            Section("Lines to highlight") {
                ForEach(DisruptionCategory.allCases) { category in
                    Toggle(isOn: categoryBinding(for: category)) {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(.glass)
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Disruption categories")
        .accessibilityValue(highlightAccessibilityValue)
    }

    private func categoryBinding(for category: DisruptionCategory) -> Binding<Bool> {
        Binding(
            get: { appState.highlightedDisruptionCategories.contains(category) },
            set: { appState.setDisruptionCategory(category, highlighted: $0) }
        )
    }

    private var highlightAccessibilityValue: String {
        let titles = DisruptionCategory.allCases
            .filter { appState.highlightedDisruptionCategories.contains($0) }
            .map(\.title)
        return titles.isEmpty ? "No categories selected" : titles.joined(separator: ", ")
    }
}

private struct PlannedWorkRow: View {
    @Environment(TubeAppState.self) private var appState
    let work: EngineeringWork
    let onSelect: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.55)) {
                appState.focus(on: work, in: appState.selectedTab)
                onSelect()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 3) {
                    ForEach(work.lineIDs) { lineID in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.tubeLine(lineID))
                            .frame(width: 5)
                    }
                }
                .frame(width: 5)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(work.lineIDs.map(\.displayName).joined(separator: ", "))
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(work.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    Text(work.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Label(validityLabel, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityHint("Highlights the planned work on the map")
    }

    private var validityLabel: String {
        let start = LondonRailDate.formatted(work.startDate, dateFormat: "EEE d MMM, HH:mm")
        let endFormat = LondonRailDate.calendar.isDate(
            work.startDate,
            inSameDayAs: work.endDate
        ) ? "HH:mm" : "EEE d MMM, HH:mm"
        let end = LondonRailDate.formatted(work.endDate, dateFormat: endFormat)
        return "\(start) – \(end)"
    }
}

private struct DisruptionRow: View {
    @Environment(TubeAppState.self) private var appState
    let disruption: ResolvedDisruption
    let onSelect: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.55)) {
                appState.select(disruption: disruption)
                onSelect()
            }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tubeLine(disruption.lineID))
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(disruption.lineID.displayName)
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        Text(disruption.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Text(disruption.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text(disruption.confidence.userDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityHint("Highlights the affected section on the map")
    }
}
