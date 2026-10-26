import SwiftUI
import TubeTrackCore

/// Owned by the Journeys tab, outside its navigation destinations and list rows.
@MainActor @Observable
final class ScheduledJourneyPresentation {
    var showsList = false
    var routeEditing: TrackedRouteSelection?
    var routeSaved = false
    var returnHomeAfterSave = false
    var showsRouteSaved = false
    var editing: ScheduledJourney?
    private(set) var deleting: ScheduledJourney?
    var showsDeleteConfirmation = false

    func confirmDeletion(of journey: ScheduledJourney) {
        deleting = journey
        showsDeleteConfirmation = true
    }
    var error: String?
}

struct ScheduledJourneysScreen: View {
    @Environment(ScheduledJourneyStore.self) private var store
    @Environment(TrackedJourneyStore.self) private var tracking: TrackedJourneyStore?
    @State private var deletingRoute: TrackedRouteSchedule?
    @Bindable var presentation: ScheduledJourneyPresentation

    var body: some View {
        List {
            if let message = store.setupError {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await store.refresh() } }
                }
            }
            if let tracking {
                trackedRoutes(tracking.schedules.filter { $0.date == nil }, title: "Regular journeys", store: tracking)
                trackedRoutes(tracking.schedules.filter { $0.date != nil }, title: "One-off journeys", store: tracking)
            }
            Section {
                if store.journeys.isEmpty && (tracking?.schedules.isEmpty ?? true) {
                    ContentUnavailableView("Your commute, ready on time", systemImage: "calendar.badge.clock",
                        description: Text("Schedule departure boards for the days and times you travel."))
                }
                ForEach(store.journeys) { journey in
                    Button { presentation.editing = journey } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(journey.title).font(.headline)
                                Spacer()
                                if !journey.enabled { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(journey.daysSummary).font(.subheadline).foregroundStyle(.secondary)
                            if let window = journey.morning { summary("Morning", window) }
                            if let window = journey.afternoon { summary("Afternoon", window) }
                        }
                        .foregroundStyle(.primary)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        // Opening a confirmation is not deletion. A destructive
                        // swipe button optimistically removes the row in SwiftUI.
                        Button("Delete") { presentation.confirmDeletion(of: journey) }
                            .tint(.red)
                    }
                    .contextMenu {
                        Button(journey.enabled ? "Pause" : "Enable", systemImage: journey.enabled ? "pause" : "play") {
                            var changed = journey
                            changed.enabled.toggle()
                            Task { do { try await store.save(changed) } catch { presentation.error = error.localizedDescription } }
                        }
                        Button("Delete", role: .destructive) { presentation.confirmDeletion(of: journey) }
                    }
                }
                Button { presentation.editing = ScheduledJourney() } label: {
                    Label("Add journey", systemImage: "plus")
                }
                .disabled(store.journeys.count >= store.maximumJourneys || store.isSaving || store.isLoading)
            } header: {
                Text("Regular departure boards · \(store.journeys.count) of \(store.maximumJourneys)")
            } footer: {
                Text("All times use London time, including British Summer Time. Manually tracked boards take priority. Journeys are saved for this installation only.")
            }
        }
        .navigationTitle("My scheduled journeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh(); await tracking?.refresh() }
        .refreshable { await store.refresh(); await tracking?.refresh() }
        .confirmationDialog("Delete this scheduled journey?", isPresented: Binding(get: { deletingRoute != nil }, set: { if !$0 { deletingRoute = nil } }), titleVisibility: .visible) {
            if let route = deletingRoute {
                Button("Delete journey", role: .destructive) { Task { await tracking?.deleteSchedule(route.id) } }
            }
        }
        .alert("Could not update journey", isPresented: Binding(get: { tracking?.error != nil }, set: { if !$0 { tracking?.error = nil } })) {
            Button("OK") { tracking?.error = nil }
        } message: { Text(tracking?.error ?? "") }

    }

    @ViewBuilder private func trackedRoutes(_ routes: [TrackedRouteSchedule], title: String, store: TrackedJourneyStore) -> some View {
        if !routes.isEmpty {
            Section(title) {
                ForEach(routes) { route in
                    Button {
                        presentation.routeEditing = TrackedRouteSelection(journey: route.plan, searchID: nil, existing: route)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(route.plan.legs.first?.from.name ?? "") → \(route.plan.legs.last?.to.name ?? "")").font(.headline)
                            if let date = route.date { Text(JourneyFormatting.date(date)) }
                            else { Text(route.days.map { ScheduledJourney.dayNames[$0 - 1] }.joined(separator: ", ") + String(format: " · %02d:%02d London", route.minute / 60, route.minute % 60)) }
                            if !route.enabled { Text("Finished · edit to schedule again").font(.caption) }
                            if let message = route.message { Text(message).font(.footnote) }
                        }.foregroundStyle(.primary)
                    }
                    .disabled(store.busy)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete") { deletingRoute = route }.tint(.red)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { presentation.routeEditing = TrackedRouteSelection(journey: route.plan, searchID: nil, existing: route) }
                        Button("Delete", role: .destructive) { deletingRoute = route }
                    }
                }
            }
        }
    }

    private func summary(_ label: String, _ window: ScheduledJourneyWindow) -> some View {
        Text("\(label): \(window.board.stationName) · \(window.timeSummary) · \(window.board.callingAtSummary)")
            .font(.subheadline).foregroundStyle(.secondary)
    }
}

struct ScheduledJourneyEditor: View {
    @Environment(ScheduledJourneyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var journey: ScheduledJourney
    @State private var morning: WindowDraft
    @State private var afternoon: WindowDraft
    @State private var error: String?
    @State private var stationPicker: ScheduledStationPeriod?
    @State private var callingPicker: ScheduledStationPeriod?
    @State private var replacement: JourneyReplacement?
    @State private var confirmsReplacement = false

    init(journey: ScheduledJourney) {
        _journey = State(initialValue: journey)
        _morning = State(initialValue: WindowDraft(window: journey.morning, start: 450))
        // Enable the return only when a station was inferred; users can add one below.
        _afternoon = State(initialValue: WindowDraft(window: journey.afternoon, start: 990))
    }

    var body: some View {
        Form {
            if !conflicts.isEmpty {
                Section {
                    Text("These times overlap with a saved journey. Replace it to use your new schedule.")
                    ForEach(conflicts) { conflict in
                        Text(conflict.replacementSummary)
                    }
                    Button(conflicts.count == 1 ? "Replace existing journey…" : "Replace existing journeys…", role: .destructive) {
                        replacement = JourneyReplacement(journey: candidate, conflicts: conflicts)
                        confirmsReplacement = true
                    }
                    .disabled(replacementError != nil || store.isSaving || store.isLoading)
                    if let replacementError { Text(replacementError).foregroundStyle(.secondary) }
                } header: { Text(conflicts.count == 1 ? "Already scheduled at this time" : "Already scheduled at these times") } footer: {
                    Text("You’ll be asked to confirm. Replacement removes the journeys shown above, including their other windows. Or choose different days or times.")
                }
            } else if let message = validationError {
                Section { Text(message).foregroundStyle(.secondary) }
            }

            Section {
                Text("Set your usual travel days and times. Check the suggested stations and directions before saving.")
                    .foregroundStyle(.secondary)
                TextField("Name (optional)", text: $journey.name)
                Toggle("Enabled", isOn: $journey.enabled)
            }
            ScheduledWindowEditor(title: "Morning · Outbound", draft: $morning, chooseStation: { stationPicker = .morning }, chooseCallingStops: { callingPicker = .morning })
            ScheduledWindowEditor(title: "Afternoon · Return", draft: $afternoon, chooseStation: { stationPicker = .afternoon }, chooseCallingStops: { callingPicker = .afternoon })
            Section("Days") {
                HStack {
                    Button("Weekdays") { journey.days = [1, 2, 3, 4, 5] }
                    Spacer()
                    Button("Weekends") { journey.days = [6, 7] }
                }
                .buttonStyle(.borderless)
                ForEach(1...7, id: \.self) { day in
                    Toggle(ScheduledJourney.dayNames[day - 1], isOn: Binding(
                        get: { journey.days.contains(day) },
                        set: { selected in
                            journey.days.removeAll { $0 == day }
                            if selected { journey.days.append(day); journey.days.sort() }
                        }
                    ))
                }
            }
            Section {
                Text("\(journey.daysSummary) · London time")
                if let w = morning.window { Text("Morning: \(w.board.stationName) · \(w.timeSummary) · \(w.board.callingAtSummary)") }
                if let w = afternoon.window { Text("Afternoon: \(w.board.stationName) · \(w.timeSummary) · \(w.board.callingAtSummary)") }
            } header: { Text("Summary") } footer: {
                Text("A Live Activity starts at each window and finishes at its end. Delivery needs a connection and Live Activities enabled. A board you track manually takes priority. Changes apply from the next window.")
            }
            if let message = store.setupError {
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry setup") { Task { await store.refresh() } }
                        .disabled(store.isLoading || store.isSaving)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Schedule journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isSaving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(store.isSaving ? "Saving…" : (conflicts.isEmpty ? "Save" : "Replace…")) {
                    if !conflicts.isEmpty {
                        replacement = JourneyReplacement(journey: candidate, conflicts: conflicts)
                        confirmsReplacement = true
                        return
                    }
                    Task {
                        do { try await store.save(candidate); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled((conflicts.isEmpty ? validationError : replacementError) != nil || store.isSaving || store.isLoading)
            }
        }
        .task { await store.refresh() }
        .interactiveDismissDisabled(store.isSaving)
        .confirmationDialog(replacement?.conflicts.count == 1 ? "Replace conflicting journey?" : "Replace conflicting journeys?", isPresented: $confirmsReplacement,
                            titleVisibility: .visible, presenting: replacement) { replacement in
            Button("Delete and save this journey", role: .destructive) {
                Task {
                    do {
                        try await store.save(replacement.journey, replacing: replacement.conflicts)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { replacement in
            Text((replacement.conflicts.count == 1 ? "This permanently deletes the following journey and all its windows, then saves this journey:\n\n" : "This permanently deletes the following journeys and all their windows, then saves this journey:\n\n")
                 + replacement.conflicts.map(\.replacementSummary).joined(separator: "\n\n"))
        }
        // A Form section is flattened into reusable rows. Present once from the
        // stable editor, rather than attaching a presenter to those rows.
        .sheet(item: $callingPicker) { period in
            let board = period == .morning ? morning.board : afternoon.board
            DepartureEndpointPicker(stops: DepartureStop.bundled.filter {
                $0.mode == "rail" && $0.id != board?.hubId && !$0.stopIDs.contains(board?.hubId ?? "")
            }, selectedIDs: board?.destinationIDs ?? [], title: "Calling at") { ids in
                switch period {
                case .morning: morning.board?.destinationIDs = ids
                case .afternoon: afternoon.board?.destinationIDs = ids
                }
            }
        }
        .sheet(item: $stationPicker) { period in
            ScheduledStationPicker(select: { stop in
                let current = period == .morning ? morning.board : afternoon.board
                let other = period == .morning ? afternoon.board : morning.board
                let preferred = current ?? other
                let board: ScheduledBoard
                if (!stop.railCodes.isEmpty && preferred?.isNationalRail == true)
                    || StationIndex.bundled.hub(containing: stop.id) == nil {
                    board = ScheduledBoard(station: stop, operatorID: "national-rail:", operatorName: nil)
                } else {
                    guard let hub = StationIndex.bundled.hub(containing: stop.id) else { return }
                    let preferredLine = preferred.flatMap { TubeLineID(rawValue: $0.lineId) }
                    guard let line = preferredLine.flatMap({ hub.lineIDs.contains($0) ? $0 : nil })
                        ?? hub.lineIDs.first else { return }
                    let direction: DepartureDirectionFilter = preferred?.lineId == line.rawValue
                        ? (current?.direction ?? other?.direction.reversed ?? .any) : .any
                    board = ScheduledBoard(hub: hub, line: line, direction: direction)
                }
                switch period {
                case .morning: morning.board = board
                case .afternoon: afternoon.board = board
                }
                stationPicker = nil
            }, cancel: { stationPicker = nil })
        }
    }

    private var candidate: ScheduledJourney {
        var value = journey
        value.morning = morning.window
        value.afternoon = afternoon.window
        return value
    }

    private var validationError: String? {
        validationError(existing: store.journeys)
    }

    private var conflicts: [ScheduledJourney] { candidate.conflictingJourneys(in: store.journeys) }

    private var replacementError: String? {
        let ids = Set(conflicts.map(\.id))
        return validationError(existing: store.journeys.filter { !ids.contains($0.id) })
    }

    private func validationError(existing: [ScheduledJourney]) -> String? {
        if (morning.enabled && morning.board == nil) || (afternoon.enabled && afternoon.board == nil) {
            return "Choose a station for each enabled window."
        }
        return ScheduledJourney.validationError(
            for: candidate, existing: existing, maximum: store.maximumJourneys)
    }
}

private struct JourneyReplacement {
    let journey: ScheduledJourney
    let conflicts: [ScheduledJourney]
}

private enum ScheduledStationPeriod: String, Identifiable {
    case morning, afternoon
    var id: Self { self }
}

private struct WindowDraft {
    var enabled: Bool
    var board: ScheduledBoard?
    var startMinute: Int
    var endMinute: Int
    init(window: ScheduledJourneyWindow?, start: Int) {
        enabled = window != nil
        board = window?.board
        startMinute = window?.startMinute ?? start
        endMinute = window?.endMinute ?? start + 120
    }
    var window: ScheduledJourneyWindow? {
        guard enabled, let board else { return nil }
        return ScheduledJourneyWindow(startMinute: startMinute, endMinute: endMinute, board: board)
    }
}

private struct ScheduledWindowEditor: View {
    let title: String
    @Binding var draft: WindowDraft
    let chooseStation: () -> Void
    let chooseCallingStops: () -> Void
    @State private var railGroups: [NationalRailDepartureGroup] = []
    @State private var directions: [DepartureDirectionFilter] = [.any]
    @State private var directionsKey: String?
    @State private var directionError: String?
    @State private var loadingDirections = false
    @State private var directionRetry = 0
    private static let arrivalsService = StationArrivalsService(client: TubeTrackAPIClient())
    private static let railService = NationalRailArrivalsService(client: TubeTrackAPIClient(
        configuration: TubeTrackAPIConfiguration(baseURL: URL(string: "https://api.skynolimit.dev/train-track")!)))

    private var services: [(id: String, name: String)] {
        guard let board = draft.board else { return [] }
        var result = StationIndex.bundled.hub(containing: board.hubId)?.lineIDs.map {
            (id: $0.rawValue, name: $0.displayName)
        } ?? []
        result += railGroups.filter { $0.operatorID != "national-rail:unknown" }.map {
            (id: $0.operatorID, name: $0.name)
        }
        if !result.contains(where: { $0.id == board.lineId }) {
            result.append((id: board.lineId, name: board.operatorName ?? "Choose operator"))
        }
        return result
    }

    private func selectService(_ id: String) {
        guard var board = draft.board else { return }
        board.lineId = id
        board.direction = .any
        board.operatorName = railGroups.first { $0.operatorID == id }?.name
        board.stopIds = board.isNationalRail ? NationalRailStations.codes(for: [board.hubId])
            : StationIndex.bundled.hub(containing: board.hubId)?.stopIDs ?? []
        draft.board = board
    }

    private var directionTaskID: String {
        "\(draft.enabled):\(draft.board?.hubId ?? ""):\(draft.board?.lineId ?? ""):\(directionRetry)"
    }

    private var directionOptions: [DepartureDirectionFilter] {
        let selected = draft.board?.direction ?? .any
        let available = directionsKey == directionTaskID ? directions : [.any]
        return available.contains(selected) ? available : available + [selected]
    }

    // A fixed winter date isolates time-of-day editing from today's DST and the device zone.
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }()

    var body: some View {
        Section {
            Toggle("Include this leg", isOn: $draft.enabled)
            if draft.enabled {
                Button(action: chooseStation) {
                    HStack {
                        Text("Station").foregroundStyle(.primary)
                        Spacer()
                        Text(draft.board?.stationName ?? "Choose station")
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }
                if let board = draft.board {
                    Button(action: chooseCallingStops) {
                        LabeledContent("Calling at", value: board.callingAtSummary)
                    }
                    .accessibilityHint("Choose the Calling at destination for this leg")
                    if !(board.destinationIDs ?? []).isEmpty {
                        Button("Show all departures") { draft.board?.destinationIDs = [] }
                    }
                    Text("Only services calling at your selected destination are shown, including intermediate stops. Leave empty for all departures.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Line or operator", selection: Binding(get: { board.lineId }, set: selectService)) {
                        ForEach(services, id: \.id) { service in Text(service.name).tag(service.id) }
                    }
                    Picker("Direction", selection: Binding(get: { board.direction }, set: { draft.board?.direction = $0 })) {
                        ForEach(directionOptions, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                }
                if draft.board?.direction == .any {
                    Text("Any direction includes trains both ways. Choose a direction if you only want departures towards your destination.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loadingDirections { ProgressView("Loading services and directions…") }
                if let directionError {
                    Text(directionError).font(.footnote).foregroundStyle(.secondary)
                    Button("Reload services and directions") { directionRetry += 1 }
                }
                DatePicker("Starts", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
        } header: { Text(title) } footer: {
            if draft.enabled { Text("London time · Maximum two hours · Ends on the same day") }
            else { Text("Add this leg to track your return departures automatically.") }
        }
        .environment(\.timeZone, calendar.timeZone)
        .task(id: directionTaskID) {
            directions = [.any]
            railGroups = []
            directionError = nil
            loadingDirections = false
            guard draft.enabled, let board = draft.board else { return }
            loadingDirections = true
            do {
                var railArrivals: [TfLArrivalPrediction] = []
                if !NationalRailStations.codes(for: [board.hubId]).isEmpty {
                    let snapshot = try await Self.railService.fetch(stationIDs: [board.hubId], forceRefresh: directionRetry > 0)
                    try Task.checkCancellation()
                    railArrivals = snapshot.arrivals
                    railGroups = NationalRailDepartureGroup.groups(from: railArrivals)
                    directionError = snapshot.errorMessage
                    if railGroups.isEmpty && board.isNationalRail {
                        directionError = "No operators are currently reported here. Try again when live departures are available."
                    }
                }
                let arrivals = board.isNationalRail ? railArrivals
                    : try await Self.arrivalsService.fetch(stationIDs: board.stopIds, forceRefresh: directionRetry > 0)
                try Task.checkCancellation()
                directions = DepartureDirectionFilter.available(in: arrivals, lineID: board.lineId)
                directionsKey = directionTaskID
                if directions == [.any] && directionError == nil {
                    directionError = "No specific directions are currently reported for this station and service. You can use Any direction or try again later."
                }
                loadingDirections = false
            } catch {
                guard !Task.isCancelled else { return }
                loadingDirections = false
                directionError = "Couldn’t load services and directions. You can use Any direction or retry."
            }
        }
    }

    private func timeBinding(_ key: WritableKeyPath<WindowDraft, Int>) -> Binding<Date> {
        let base = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        return Binding(get: { base.addingTimeInterval(Double(draft[keyPath: key]) * 60) }, set: { value in
            let parts = calendar.dateComponents([.hour, .minute], from: value)
            draft[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

private struct ScheduledStationPicker: View {
    @State private var query = ""
    let select: (DepartureStop) -> Void
    private var stations: [DepartureStop] {
        DepartureStop.bundled.filter { stop in
            stop.mode != "river" && (!stop.railCodes.isEmpty || StationIndex.bundled.hub(containing: stop.id) != nil)
                && (query.isEmpty || stop.name.localizedStandardContains(query))
        }
    }
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            List(stations) { hub in
                Button {
                    select(hub)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hub.name).foregroundStyle(.primary)
                        Text((hub.lineIDs.compactMap { TubeLineID(rawValue: $0)?.displayName } + (hub.railCodes.isEmpty ? [] : ["National Rail"])).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Station name")
            .navigationTitle("Choose station")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
    }
}

#Preview("Schedule · Light") {
    NavigationStack { ScheduledJourneyEditor(journey: ScheduledJourney()) }
        .environment(ScheduledJourneyStore())
        .preferredColorScheme(.light)
}

#Preview("Schedule · Dark · Large text") {
    NavigationStack { ScheduledJourneyEditor(journey: ScheduledJourney()) }
        .environment(ScheduledJourneyStore())
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
