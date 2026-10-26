import SwiftUI
import TubeTrackCore

struct JourneyTrackingScreen: View {
    @Environment(TrackedJourneyStore.self) private var store
    @Environment(TubeAppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var callingPoints: SelectedRailDeparture?
    @State private var ending = false

    var body: some View {
        NavigationStack {
            List {
                if let journey = store.active {
                    summary(journey)
                    if let index = journey.boardIndex { board(journey, index: index) }
                    Section("Journey progress") {
                        Picker("Current leg", selection: Binding(get: { journey.legIndex }, set: { index in
                            Task { await store.progress(index: index, phase: "waiting", id: journey.id) }
                        })) {
                            ForEach(journey.transitIndices, id: \.self) { index in
                                Text("\(journey.plan.legs[index].from.name) → \(journey.plan.legs[index].to.name)").tag(index)
                            }
                        }
                        if journey.phase == "waiting" {
                            Button("I’m on the train") { Task { await store.progress(index: journey.legIndex, phase: "onboard", id: journey.id) } }
                        } else if let next = journey.transitIndices.first(where: { $0 > journey.legIndex }) {
                            Button("I’ve arrived at \(journey.currentLeg.to.name)") {
                                Task { await store.progress(index: next, phase: "waiting", id: journey.id) }
                            }
                        } else {
                            Button("I’ve arrived") { Task { await store.progress(index: journey.legIndex, phase: "complete", id: journey.id) } }
                        }
                        Toggle("Follow my location", isOn: Binding(get: { store.locationEnabled }, set: store.setLocation))
                        Text(store.locationEnabled ? store.location.message ?? "Finding your location…"
                             : "Optional: use location during this journey, including while locked. Coordinates stay on your phone. You can always correct progress above.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(store.busy)
                    Section("Full route") {
                        ForEach(Array(journey.plan.legs.enumerated()), id: \.offset) { index, leg in
                            DisclosureGroup {
                                Text(leg.instruction)
                                LabeledContent("Planned departure", value: JourneyFormatting.time(leg.departureTime))
                                LabeledContent("Planned arrival", value: JourneyFormatting.time(leg.arrivalTime))
                                if let platform = leg.from.platform { Text("Platform \(platform) · check live board") }
                                ForEach(leg.warnings) { warning in Text(warning.message).foregroundStyle(.secondary) }
                                ForEach(Array(leg.stops.enumerated()), id: \.offset) { _, stop in Text(stop.name) }
                                if let request = leg.trackingBoard {
                                    NavigationLink("Full departure board") { DepartureBoardCard(initialRequest: request, usesSavedView: false) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(leg.from.name) → \(leg.to.name)")
                                    Text(index == journey.legIndex ? "Current leg" : leg.lines.map(\.name).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        NavigationLink("Journey map") { JourneyMapScreen(journey: journey.plan) }
                    }
                    Section {
                        Button("Find alternative routes") { alternatives(journey) }
                        Text("Your selected route stays active until you accept another route. Alternatives start at your next stop while you’re on a train.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("End journey", role: .destructive) { ending = true }
                    }
                } else {
                    ContentUnavailableView("No active journey", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("Choose a route on the Journeys screen to start tracking."))
                }
                if let error = store.error { Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) } }
            }
            .navigationTitle("Your journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await store.refresh() }
            .fullScreenCover(item: $callingPoints) { RailCallingPointsSheet(arrival: $0.arrival) }
            .confirmationDialog("End this journey?", isPresented: $ending, titleVisibility: .visible) {
                Button("End journey", role: .destructive) {
                    if let journey = store.active { Task { await store.progress(index: journey.legIndex, phase: "complete", id: journey.id) } }
                }
            }
        }
    }
    @ViewBuilder private func summary(_ journey: TrackedJourney) -> some View {
        Section {
            if let state = journey.state {
                Text(state.headline).font(.title2.bold())
                if let service = journey.boardedService, service.supportsCallingPoints {
                    Button("Current train service info") { callingPoints = .init(arrival: service) }
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("\(state.nextStop) ETA", value: eta(state.nextArrivalEpoch))
                        LabeledContent("\(state.destination) ETA", value: eta(state.finalArrivalEpoch)).font(.headline)
                        if state.isStale(at: context.date) || app.isOffline {
                            Label("Updates delayed · last checked \(JourneyFormatting.time(Date(timeIntervalSince1970: Double(state.updatedAtEpoch))))", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        if !state.message.isEmpty { Text(state.message).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    @ViewBuilder private func board(_ journey: TrackedJourney, index: Int) -> some View {
        let leg = journey.plan.legs[index]
        Section("\(leg.from.name) → \(leg.to.name) departures") {
            if let board = journey.boards?[String(index)] {
                ForEach(Array(board.arrivals.prefix(6)), id: \.id) { arrival in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(arrival.destinationName ?? "Check front of train").font(.headline)
                                Text("Calls at \(leg.to.name)").font(.caption)
                                if let serviceID = leg.serviceID, arrival.id.hasSuffix(":" + serviceID) { Text("Planned service").font(.caption.bold()) }
                            }
                            Spacer()
                            if let time = arrival.expectedArrival { Text(JourneyFormatting.time(time)).monospacedDigit() }
                            else { Text("Time unconfirmed") }
                        }
                        if let platform = arrival.platformName { Text(platform).font(.subheadline) }
                        if arrival.serviceStatus == .cancelled { Text("Cancelled").foregroundStyle(.red) }
                        else if arrival.serviceStatus == .delayed { Text("Delayed").foregroundStyle(.orange) }
                        HStack {
                            if arrival.supportsCallingPoints {
                                Button("Service info") { callingPoints = .init(arrival: arrival) }.buttonStyle(.borderless)
                            }
                            Spacer()
                            Button("I’m on this train") {
                                Task { await store.progress(index: index, phase: "onboard", id: journey.id, boardedID: arrival.id) }
                            }.buttonStyle(.borderless)
                                .disabled(store.busy || app.isOffline || board.stale || arrival.serviceStatus == .cancelled
                                    || Date.now.timeIntervalSince(board.updatedAt) > 90)
                        }
                    }.padding(.vertical, 4)
                }
                if board.arrivals.isEmpty { Text("No verified departures available. Pull to refresh or check the full board.").foregroundStyle(.secondary) }
                if let headline = board.conditionHeadline { Label(headline, systemImage: "exclamationmark.triangle") }
            } else { Text("Live departures unavailable. Pull to refresh.").foregroundStyle(.secondary) }
            if let request = leg.trackingBoard {
                NavigationLink("Full departure board") { DepartureBoardCard(initialRequest: request, usesSavedView: false) }
            }
        }
    }
    private func eta(_ epoch: Int?) -> String { epoch.map { JourneyFormatting.time(Date(timeIntervalSince1970: Double($0))) } ?? "Checking connection" }
    private func alternatives(_ journey: TrackedJourney) {
        let origin = journey.phase == "onboard" ? journey.currentLeg.to.id : journey.currentLeg.from.id
        func station(_ id: String) -> TubeStation? {
            app.graph?.stations.first { $0.id == id || $0.hubID == id }
        }
        guard let from = station(origin), let to = station(journey.plan.legs.last!.to.id) else { store.error = "Choose alternative endpoints in the journey search."; dismiss(); return }
        app.journeyPlanner.from = from; app.journeyPlanner.to = to; app.journeyPlanner.via = []
        if journey.phase == "onboard", let eta = journey.state?.nextArrivalEpoch {
            app.journeyPlanner.timeMode = .departAt
            app.journeyPlanner.time = max(.now, Date(timeIntervalSince1970: Double(eta)).addingTimeInterval(120))
        } else { app.journeyPlanner.timeMode = .now }
        app.journeyPlanner.startSearch(); dismiss()
    }
}

extension JourneyLeg {
    var trackingBoard: DepartureBoardRequest? {
        func stop(_ id: String) -> DepartureStop? { DepartureStop.bundled.first { $0.id == id || $0.stopIDs.contains(id) || $0.railCodes.contains(id) } }
        guard !["walking", "transfer", "replacement-bus"].contains(mode), let origin = stop(from.id), let destination = stop(to.id) else { return nil }
        let ids = lines.map { line in
            if let code = line.operatorCode, !["LO", "XR", "TL"].contains(code) { return "national-rail:" + code }
            return line.tubeLineID?.rawValue ?? line.id
        }
        return .init(originID: origin.id, destinationIDs: [destination.id], lineIDs: ids)
    }
}

struct TrackedRouteSelection: Identifiable {
    let id = UUID()
    let journey: PlannedJourney
    let searchID: String?
    var existing: TrackedRouteSchedule? = nil
}

struct TrackedRouteScheduleEditor: View {
    @Environment(TrackedJourneyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let journey: PlannedJourney
    let searchID: String?
    @State private var repeats = false
    @State private var date = Date.now.addingTimeInterval(600)
    @State private var days: Set<Int> = [1, 2, 3, 4, 5]
    @State private var saveError: String?
    @State private var saving = false
    let existing: TrackedRouteSchedule?
    let onSaved: () -> Void

    init(journey: PlannedJourney, searchID: String?, existing: TrackedRouteSchedule? = nil, onSaved: @escaping () -> Void = {}) {
        self.journey = journey; self.searchID = searchID; self.existing = existing; self.onSaved = onSaved
        _repeats = State(initialValue: existing.map { $0.date == nil } ?? false)
        let calendar = LondonRailDate.calendar
        let minute = existing?.minute ?? 0
        let repeatDate = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        _date = State(initialValue: existing.map { $0.date.map { max($0, .now.addingTimeInterval(600)) } ?? repeatDate } ?? max(.now.addingTimeInterval(600), journey.departureTime.addingTimeInterval(-600)))
        _days = State(initialValue: Set(existing?.days ?? [1, 2, 3, 4, 5]))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(journey.legs.first?.from.name ?? "") → \(journey.legs.last?.to.name ?? "")").font(.headline)
                    ForEach(journey.legs.filter { !["walking", "transfer"].contains($0.mode) }) { leg in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(leg.from.name) → \(leg.to.name)")
                            ForEach(leg.lines, id: \.id) { line in
                                HStack { JourneyLineDot(line: line, diameter: 12); Text(line.name).font(.subheadline) }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Make this a regular journey", isOn: $repeats)
                    if repeats {
                        DatePicker("Start tracking", selection: $date, displayedComponents: [.hourAndMinute])
                            .environment(\.timeZone, LondonRailDate.calendar.timeZone)
                    } else {
                        DatePicker("Start tracking", selection: $date, in: Date.now...Date.now.addingTimeInterval(59 * 86400), displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, LondonRailDate.calendar.timeZone)
                    }
                    if repeats {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day - 1], isOn: Binding(get: { days.contains(day) }, set: { enabled in
                                if enabled { days.insert(day) } else { days.remove(day) }
                            }))
                        }
                    }
                } footer: {
                    Text("Times are London time. At the start time we find fresh services on this route and start a Live Activity. Open the journey to enable location following. If the route is unavailable, check Journeys for details.")
                }
                Button(saving ? "Saving…" : existing == nil ? "Schedule journey" : "Save changes") {
                    saving = true
                    let calendar = LondonRailDate.calendar
                    let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                    Task {
                        defer { saving = false }
                        if await store.schedule(journey, searchID: searchID, date: repeats ? nil : date, days: Array(days).sorted(), minute: minute, editingID: existing?.id) {
                            onSaved(); dismiss()
                        } else {
                            saveError = store.error ?? "The journey could not be scheduled. Please try again."
                        }
                    }
                }.disabled(saving || (repeats && days.isEmpty))
                .buttonStyle(.borderless)
            }
            .navigationTitle("Schedule route")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .alert("Journey not scheduled", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }

        }
    }
}

struct TrackedRouteActions: View {
    @Environment(TrackedJourneyStore.self) private var store: TrackedJourneyStore?
    @Environment(TubeAppState.self) private var app
    let journey: PlannedJourney
    let searchID: String?
    let onSchedule: () -> Void
    @State private var replacing = false
    static func canStart(_ journey: PlannedJourney, at now: Date) -> Bool {
        journey.departureTime <= now.addingTimeInterval(7200)
    }
    var body: some View {
        if let store {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if Self.canStart(journey, at: context.date) {
            Button {
                if store.active != nil { replacing = true } else { Task { await store.start(journey, searchID: searchID) } }
            } label: { Label("Start journey", systemImage: "play.fill") }
                .disabled(store.busy || app.isOffline)
                }
            }
            Button(action: onSchedule) { Label("Schedule this route", systemImage: "calendar.badge.plus") }
                .disabled(store.busy || app.isOffline)
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Color.clear.frame(height: 0)
                .confirmationDialog("Replace your active journey with this route?", isPresented: $replacing, titleVisibility: .visible) {
                    Button("Use this route") {
                        Task {
                            await store.start(journey, searchID: searchID, replacing: true)
                        }
                    }
                }
        }
    }
}
