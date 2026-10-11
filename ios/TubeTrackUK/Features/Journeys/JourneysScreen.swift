import SwiftUI

struct JourneysScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(ScheduledJourneyStore.self) private var scheduleStore
    @State private var showsResults = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var planner = appState.journeyPlanner

        NavigationStack {
            List {
                Section {
                    scheduledJourneysLink
                }

                Section {
                    stationButton("From", station: planner.from, field: .from)
                    stationButton("To", station: planner.to, field: .to)
                    Button {
                        planner.swapStations()
                    } label: {
                        Label("Swap stations", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(planner.from == nil && planner.to == nil)
                }

                Section {
                    Picker("When", selection: $planner.timeMode) {
                        ForEach(JourneyTimeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if planner.timeMode != .now {
                        DatePicker(
                            planner.timeMode.title, selection: $planner.time,
                            in: Date.now...Date.now.addingTimeInterval(59 * 86_400),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .environment(\.timeZone, LondonRailDate.calendar.timeZone)
                    }
                    Picker("Step-free access", selection: $planner.accessibility) {
                        ForEach(JourneyAccessibility.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } footer: {
                    Text(planner.accessibility == .none
                         ? "National Rail, Tube, DLR, Elizabeth line, Overground, trams and official replacement buses, with walking connections. Times are London time."
                         : "TfL legs use your step-free preference. National Rail and replacement-bus accessibility may be unverified. Check station notices and assistance requirements.")
                }

                Section {
                    Button {
                        guard !planner.isLoading else { return }
                        planner.startSearch()
                    } label: {
                        HStack {
                            Spacer()
                            if planner.isLoading {
                                ProgressView().tint(.white).controlSize(.regular)
                                    .accessibilityLabel("Finding journeys")
                            }
                            Text(planner.isLoading ? "Finding journeys…" : "Find journeys")
                                .font(.appHeadline(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.tubeBlue)
                    .foregroundStyle(.white)
                    .disabled(!planner.canSearch || appState.isOffline)
                    .allowsHitTesting(!planner.isLoading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } footer: {
                    if planner.hasSameStation {
                        Text("Choose a different destination.")
                    }
                    if appState.isOffline {
                        Label("Connect to the internet to plan a journey.", systemImage: "wifi.slash")
                    }
                }

                if let error = planner.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if !planner.isLoading && planner.errorMessage == nil {
                    Section {
                        ContentUnavailableView(
                            "Where are you heading?", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            description: Text("Choose two stations to compare journey times and reported disruption.")
                        )
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Journeys")
            .journeyBackground()
            .navigationDestination(isPresented: $showsResults) {
                resultsDestination
            }

        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .task(id: planner.searchID) { await planner.load() }
        .onChange(of: planner.result?.updatedAt) { _, updatedAt in
            showsResults = updatedAt != nil
        }
        .onDisappear { planner.cancelSearch() }
        .onChange(of: appState.isOffline) { _, offline in
            if offline { planner.cancelSearch() }
        }
    }

    private var scheduledJourneysLink: some View {
        let count = scheduleStore.journeys.count
        return NavigationLink {
            ScheduledJourneysScreen()
        } label: {
            if dynamicTypeSize >= .accessibility4 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .accessibilityHidden(true)
                        Spacer()
                        scheduledJourneyBadge
                    }
                    Text("Scheduled journeys")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Label("Scheduled journeys", systemImage: "calendar.badge.clock")
                    Spacer()
                    scheduledJourneyBadge
                }
            }
        }
        .accessibilityValue(count == 1 ? "1 journey" : "\(count) journeys")
    }

    @ViewBuilder
    private var scheduledJourneyBadge: some View {
        if !scheduleStore.journeys.isEmpty {
            Text(scheduleStore.journeys.count, format: .number)
                .font(.appCaption(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.tubeBlue, in: Capsule())
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var resultsDestination: some View {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-DebugJourneyDestination"),
           arguments.indices.contains(index + 1),
           let response = appState.journeyPlanner.result,
           let journey = response.data.journeys.first {
            if arguments[index + 1] == "map" {
                JourneyMapScreen(journey: journey)
            } else if arguments[index + 1] == "details" {
                JourneyDetailScreen(journey: journey, expiresAt: response.data.expiresAt, isStale: response.stale)
            } else {
                JourneyResultsScreen()
            }
        } else {
            JourneyResultsScreen()
        }
        #else
        JourneyResultsScreen()
        #endif
    }

    private func stationButton(_ title: String, station: TubeStation?, field: JourneyPlannerModel.StationField) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return Button { appState.journeyPlanner.stationField = field } label: {
            layout {
                Text(title)
                    .font(dynamicTypeSize.isAccessibilitySize ? .appCaption() : .appBody())
                    .foregroundStyle(.secondary)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 42, alignment: .leading)
                HStack(alignment: .firstTextBaseline) {
                    Text(station?.name ?? "Choose station")
                        .font(.appBody(.semibold))
                        .foregroundStyle(station == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 5)
        }
        .disabled(appState.graph == nil)
        .accessibilityLabel("\(title), \(station?.name ?? "choose station")")
    }

}

private struct JourneyResultsScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if appState.journeyPlanner.isLoading {
                Section { ProgressView("Refreshing journeys…") }
            }
            if let error = appState.journeyPlanner.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Try again") { appState.journeyPlanner.startSearch(keepingResults: true) }
                        .disabled(appState.isOffline || appState.journeyPlanner.isLoading)
                }
            }
            if let response = appState.journeyPlanner.result { results(response) }
        }
        .refreshable {
            guard !appState.isOffline else { return }
            await appState.journeyPlanner.refreshSuggestions()
        }
        .navigationTitle("Route suggestions")
        .navigationBarTitleDisplayMode(.inline)
        .journeyBackground()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !appState.isOffline { appState.journeyPlanner.refreshIfNeeded() }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    @ViewBuilder
    private func results(_ response: TubeTrackAPIResponse<JourneyPlan>) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let expired = context.date >= response.data.expiresAt || response.stale || appState.isOffline
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(response.data.from.name) to \(response.data.to.name)")
                        .font(.appHeadline())
                    Text(JourneyFormatting.date(response.data.requestedAt))
                        .font(.appSubheadline()).foregroundStyle(.secondary)
                    Label(
                        expired ? "Results need refreshing" : "Checked \(JourneyFormatting.time(response.updatedAt))",
                        systemImage: expired ? "clock.badge.exclamationmark" : "clock"
                    )
                    .font(.appCaption())
                    .foregroundStyle(expired ? Color.orange : .secondary)
                    if expired {
                        Button("Refresh route suggestions") { appState.journeyPlanner.startSearch(keepingResults: true) }
                            .disabled(appState.isOffline || appState.journeyPlanner.isLoading)
                    }
                }
            }
        } header: {
            if response.data.journeys.isEmpty { Text("No journeys found") }
        }

        ForEach(response.data.journeys) { journey in
            Section {
                NavigationLink {
                    JourneyDetailScreen(journey: journey, expiresAt: response.data.expiresAt, isStale: response.stale)
                } label: {
                    JourneySummary(journey: journey)
                }
            }
        }

        if !response.data.messages.isEmpty {
            Section {
                if response.data.journeys.isEmpty {
                    ForEach(response.data.messages, id: \.self) { message in
                        Text(message).font(.appSubheadline()).foregroundStyle(.secondary)
                    }
                } else {
                    DisclosureGroup("Travel notices (\(response.data.messages.count))") {
                        ForEach(response.data.messages, id: \.self) { message in
                            Text(message).font(.appSubheadline()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Section {
            Text("Times are estimates. Disruption can change journey times, and an alternative may not always be available.")
            Text(response.data.attribution)
        }
        .font(.appCaption())
        .foregroundStyle(.secondary)
        .listRowBackground(Color.clear)
    }
}

private struct JourneySummary: View {
    @Environment(\.colorScheme) private var colorScheme
    let journey: PlannedJourney

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recommendation = journey.recommendation {
                Label(recommendation, systemImage: journey.labels.contains("lessDisrupted") ? "arrow.triangle.branch" : "clock")
                    .font(.appCaption(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white : .tubeBlue)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    times
                    Spacer(minLength: 12)
                    Text(JourneyFormatting.duration(journey.durationMinutes)).font(.appHeadline())
                }
                VStack(alignment: .leading, spacing: 4) {
                    times
                    Text(JourneyFormatting.duration(journey.durationMinutes)).font(.appHeadline())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(journey.distinctLines.enumerated()), id: \.offset) { _, line in
                    if line.operatorCode != nil {
                        Text(line.name)
                            .font(.appSubheadline(.semibold))
                            .foregroundStyle(line.brandForeground)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(line.brandColour, in: Capsule())
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 8) {
                            JourneyLineDot(line: line, diameter: 12)
                            Text(line.name).font(.appSubheadline(.medium))
                        }
                    }
                }
            }
            if !LondonRailDate.calendar.isDate(journey.departureTime, inSameDayAs: journey.arrivalTime) {
                Text("Arrives \(JourneyFormatting.date(journey.arrivalTime))")
                    .font(.appCaption()).foregroundStyle(.secondary)
            }
            Text("\(journey.changes) \(journey.changes == 1 ? "change" : "changes") · \(journey.walkingMinutes) min walking")
                .font(.appCaption()).foregroundStyle(.secondary)
            if journey.waitingMinutes > 0 {
                Text("Leaves in \(journey.waitingMinutes) min from the search time")
                    .font(.appCaption()).foregroundStyle(.secondary)
            }
            if !journey.severeWarnings.isEmpty {
                Label("Severe disruption reported", systemImage: "exclamationmark.triangle.fill")
                    .font(.appCaption(.semibold)).foregroundStyle(.orange)
            } else if !journey.warnings.isEmpty {
                Label("Check travel notices", systemImage: "info.circle")
                    .font(.appCaption()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var times: some View {
        HStack(spacing: 8) {
            Text(JourneyFormatting.time(journey.departureTime))
            Image(systemName: "arrow.right")
                .font(.system(size: 17, weight: .medium))
                .accessibilityHidden(true)
            Text(JourneyFormatting.time(journey.arrivalTime))
        }
        .font(.appTitle2(.bold)).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Departs \(JourneyFormatting.time(journey.departureTime)), arrives \(JourneyFormatting.time(journey.arrivalTime))")
    }
}

#Preview("Journey planner") {
    let state: TubeAppState = {
        let state = TubeAppState(monitorsConnectivity: false)
        state.graph = try? TubeGraph.bundled()
        return state
    }()
    JourneysScreen()
        .environment(state)
        .environment(ScheduledJourneyStore(observesTokens: false))
}

#Preview("Journey planner · Large text") {
    JourneysScreen()
        .environment(TubeAppState(monitorsConnectivity: false))
        .environment(ScheduledJourneyStore(observesTokens: false))
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}

struct JourneyDetailScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let journey: PlannedJourney
    let expiresAt: Date
    var isStale = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    JourneySummary(journey: journey)
                    Text(JourneyFormatting.date(journey.departureTime))
                        .font(.appCaption()).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if context.date >= expiresAt || isStale || appState.isOffline {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("This plan needs refreshing.", systemImage: "clock.badge.exclamationmark")
                                    .font(.appSubheadline()).foregroundStyle(.orange)
                                Button {
                                    appState.journeyPlanner.startSearch(keepingResults: true)
                                    dismiss()
                                } label: {
                                    Label("Refresh route suggestions", systemImage: "arrow.clockwise")
                                        .font(.appBody(.semibold))
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .buttonStyle(.bordered)
                                .disabled(appState.isOffline)
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    JourneyMapScreen(journey: journey)
                } label: {
                    Label("Show journey map", systemImage: "map")
                }
            }
            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        if ["walking", "transfer", "replacement-bus"].contains(leg.mode) {
                            Image(systemName: leg.mode == "replacement-bus" ? "bus.fill" : leg.mode == "transfer" ? "arrow.triangle.swap" : "figure.walk")
                                .font(.title2).accessibilityHidden(true)
                        } else {
                            ForEach(Array(leg.lines.enumerated()), id: \.offset) { _, line in
                                JourneyLineDot(line: line, diameter: 26)
                            }
                        }
                        Text(leg.instruction).font(.appHeadline())
                    }
                    LabeledContent(JourneyFormatting.time(leg.departureTime), value: leg.from.name)
                    LabeledContent(JourneyFormatting.time(leg.arrivalTime), value: leg.to.name)
                    if let platform = leg.from.platform, !platform.isEmpty {
                        Text("Platform \(platform)")
                    }
                    ForEach(Array(leg.lines.enumerated()), id: \.offset) { _, line in
                        if !line.direction.isEmpty {
                            Text("Towards \(line.direction)").font(.appSubheadline()).foregroundStyle(.secondary)
                        }
                    }
                    if leg.timing == "adjusted" {
                        Text("Timing adjusted by TfL").font(.appCaption()).foregroundStyle(.secondary)
                    } else if leg.timing == "live" {
                        Text("Live service times").font(.appCaption()).foregroundStyle(.secondary)
                    } else if leg.timing == "scheduled", ["national-rail", "replacement-bus"].contains(leg.mode) {
                        Label("Timetable times · live information unavailable", systemImage: "clock.badge.exclamationmark")
                            .font(.appCaption()).foregroundStyle(.secondary)
                    }
                    if let scheduled = leg.scheduledDepartureTime, scheduled != leg.departureTime {
                        Text("Scheduled departure \(JourneyFormatting.time(scheduled))")
                            .font(.appCaption()).foregroundStyle(.secondary)
                    }
                    if !leg.stops.isEmpty {
                        DisclosureGroup("Stops") {
                            ForEach(Array(leg.stops.enumerated()), id: \.offset) { _, stop in
                                Text(stop.name).font(.appSubheadline())
                            }
                        }
                    }
                    ForEach(leg.warnings) { warning in
                        VStack(alignment: .leading, spacing: 5) {
                            if warning.kind == "accessibility" {
                                Text("Station accessibility notice").font(.appCaption(.semibold))
                            }
                            Label(warning.message, systemImage: warning.severity == "severe" ? "exclamationmark.triangle" : "info.circle")
                                .font(.appSubheadline())
                        }
                        .foregroundStyle(warning.severity == "severe" ? Color.orange : .secondary)
                    }
                } header: {
                    Text("Leg \(index + 1) · \(JourneyFormatting.duration(leg.durationMinutes))")
                } footer: {
                    if index + 1 < journey.legs.count {
                        let next = journey.legs[index + 1]
                        let gap = Int(next.departureTime.timeIntervalSince(leg.arrivalTime) / 60)
                        if gap > 0 { Text("\(gap) min to change or wait for the next service") }
                    }
                }
            }
        }
        .journeyBackground()
        .navigationTitle("Journey details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct JourneyLineDot: View {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    let line: JourneyLine
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(line.operatorCode != nil ? line.brandColour : line.tubeLineID.map { Color.tubeLine($0) } ?? .secondary)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1) }
            .frame(width: diameter * min(scale, 2), height: diameter * min(scale, 2))
            .accessibilityHidden(true)
    }
}

private extension JourneyLine {
    var brandRGB: (Double, Double, Double) {
        guard let colour, colour.count == 7, colour.first == "#",
              let rgb = UInt32(colour.dropFirst(), radix: 16) else { return (0.35, 0.39, 0.43) }
        return (Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255)
    }
    var brandColour: Color {
        let (r, g, b) = brandRGB
        return Color(red: r, green: g, blue: b)
    }
    var brandForeground: Color {
        let (r, g, b) = brandRGB
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.179 ? .black : .white
    }
}

private extension View {
    func journeyBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}
