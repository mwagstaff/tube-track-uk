import SwiftUI
import TubeTrackCore

struct ScheduledJourneysScreen: View {
    @Environment(ScheduledJourneyStore.self) private var store
    @State private var editing: ScheduledJourney?
    @State private var deleting: ScheduledJourney?
    @State private var error: String?

    var body: some View {
        List {
            if let message = store.setupError {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await store.refresh() } }
                }
            }
            Section {
                if store.journeys.isEmpty {
                    ContentUnavailableView("Your commute, ready on time", systemImage: "calendar.badge.clock",
                        description: Text("Schedule departure boards for the days and times you travel."))
                }
                ForEach(store.journeys) { journey in
                    Button { editing = journey } label: {
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
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = journey }
                    }
                    .contextMenu {
                        Button(journey.enabled ? "Pause" : "Enable", systemImage: journey.enabled ? "pause" : "play") {
                            var changed = journey
                            changed.enabled.toggle()
                            Task { do { try await store.save(changed) } catch { self.error = error.localizedDescription } }
                        }
                        Button("Delete", role: .destructive) { deleting = journey }
                    }
                }
                Button { editing = ScheduledJourney() } label: {
                    Label("Add journey", systemImage: "plus")
                }
                .disabled(store.journeys.count >= store.maximumJourneys || store.isSaving || store.isLoading)
            } header: {
                Text("\(store.journeys.count) of \(store.maximumJourneys) journeys")
            } footer: {
                Text("All times use London time, including British Summer Time. Manually tracked boards take priority. Journeys are saved for this installation only.")
            }
        }
        .navigationTitle("Scheduled journeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
        .sheet(item: $editing) { journey in
            NavigationStack { ScheduledJourneyEditor(journey: journey) }
        }
        .confirmationDialog("Delete this scheduled journey?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete journey", role: .destructive) {
                guard let journey = deleting else { return }
                Task { do { try await store.delete(journey) } catch { self.error = error.localizedDescription } }
            }
        }
        .alert("Could not update journey", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func summary(_ label: String, _ window: ScheduledJourneyWindow) -> some View {
        Text("\(label): \(window.board.stationName) · \(window.timeSummary)")
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
    @State private var replacement: JourneyReplacement?
    @State private var confirmsReplacement = false

    init(journey: ScheduledJourney) {
        _journey = State(initialValue: journey)
        _morning = State(initialValue: WindowDraft(window: journey.morning, start: 8 * 60))
        _afternoon = State(initialValue: WindowDraft(window: journey.afternoon, start: 16 * 60))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $journey.name)
                Toggle("Enabled", isOn: $journey.enabled)
            }
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
            ScheduledWindowEditor(title: "Morning", draft: $morning) { stationPicker = .morning }
            ScheduledWindowEditor(title: "Afternoon", draft: $afternoon) { stationPicker = .afternoon }
            Section {
                Text("\(journey.daysSummary) · London time")
                if let w = morning.window { Text("Morning: \(w.board.stationName) · \(w.timeSummary)") }
                if let w = afternoon.window { Text("Afternoon: \(w.board.stationName) · \(w.timeSummary)") }
            } header: { Text("Summary") } footer: {
                Text("A Live Activity starts at each window and finishes at its end. Delivery needs a connection and Live Activities enabled. A board you track manually takes priority. Changes apply from the next window.")
            }
            if !conflicts.isEmpty {
                Section {
                    Text(conflicts.count == 1 ? "This saved journey uses the same days and overlapping times. Only one scheduled board can run at a time." : "These saved journeys use the same days and overlapping times. Only one scheduled board can run at a time.")
                    ForEach(conflicts) { conflict in
                        Text(conflict.replacementSummary)
                    }
                    Button(conflicts.count == 1 ? "Replace conflicting journey…" : "Replace conflicting journeys…", role: .destructive) {
                        replacement = JourneyReplacement(journey: candidate, conflicts: conflicts)
                        confirmsReplacement = true
                    }
                    .disabled(replacementError != nil || store.isSaving || store.isLoading)
                    if let replacementError { Text(replacementError).foregroundStyle(.secondary) }
                } header: { Text(conflicts.count == 1 ? "Conflicts with a saved journey" : "Conflicts with saved journeys") } footer: {
                    Text(conflicts.count == 1 ? "Replace deletes the entire conflicting journey, including its other windows, and saves this journey. You can also change these days or times, or edit or pause the saved journey in Profile." : "Replace deletes the entire conflicting journeys, including their other windows, and saves this journey. You can also change these days or times, or edit or pause the saved journeys in Profile.")
                }
            } else if let message = validationError {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Schedule journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isSaving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(store.isSaving ? "Saving…" : "Save") {
                    Task {
                        do { try await store.save(candidate); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(validationError != nil || store.isSaving || store.isLoading)
            }
        }
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
        .sheet(item: $stationPicker) { period in
            ScheduledStationPicker(select: { hub in
                guard let line = hub.lineIDs.first else { return }
                let board = ScheduledBoard(hub: hub, line: line)
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
    @State private var directions: [DepartureDirectionFilter] = [.any]
    @State private var directionsKey: String?
    @State private var directionError: String?
    @State private var loadingDirections = false
    @State private var directionRetry = 0
    private static let arrivalsService = StationArrivalsService(client: TubeTrackAPIClient())

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
            Toggle("\(title) departures", isOn: $draft.enabled)
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
                if let board = draft.board, let hub = StationIndex.bundled.hub(containing: board.hubId) {
                    Picker("Line", selection: Binding(get: { board.lineId }, set: { value in
                        draft.board?.lineId = value
                        draft.board?.direction = .any
                    })) {
                        ForEach(hub.lineIDs) { line in Text(line.displayName).tag(line.rawValue) }
                    }
                    Picker("Direction", selection: Binding(get: { board.direction }, set: { draft.board?.direction = $0 })) {
                        ForEach(directionOptions, id: \.self) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                }
                if loadingDirections { ProgressView("Loading directions…") }
                if let directionError {
                    Text(directionError).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry directions") { directionRetry += 1 }
                }
                DatePicker("Starts", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
        } header: { Text(title) } footer: {
            if draft.enabled { Text("London time · Maximum two hours · Ends on the same day") }
        }
        .environment(\.timeZone, calendar.timeZone)
        .task(id: directionTaskID) {
            directions = [.any]
            directionError = nil
            loadingDirections = false
            guard draft.enabled, let board = draft.board else { return }
            loadingDirections = true
            do {
                let arrivals = try await Self.arrivalsService.fetch(stationIDs: board.stopIds, forceRefresh: directionRetry > 0)
                try Task.checkCancellation()
                directions = DepartureDirectionFilter.available(in: arrivals, lineID: board.lineId)
                directionsKey = directionTaskID
                if directions == [.any] {
                    directionError = "No specific directions are currently reported for this station and line. You can use Any direction or try again later."
                }
                loadingDirections = false
            } catch {
                guard !Task.isCancelled else { return }
                loadingDirections = false
                directionError = "Couldn’t load directions. You can use Any direction or retry."
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
    let select: (StationHub) -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            List(StationIndex.bundled.search(query)) { hub in
                Button {
                    select(hub)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hub.name).foregroundStyle(.primary)
                        Text(hub.lineIDs.map(\.displayName).joined(separator: " · "))
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
