import SwiftUI

struct DepartureBoardEditor: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var draft: DepartureFavourite
    var savingFavourite = true
    let onSave: (DepartureFavourite) -> Void
    @State private var picker: EndpointSelection?
    private enum EndpointSelection: String, Identifiable {
        case origin, destinations
        var id: String { rawValue }
    }

    private var origin: DepartureStop? { appState.departureStop(id: draft.outbound.originID) }
    private var lineChoices: [String] {
        let known = origin?.lineIDs ?? []
        let live = appState.departureBoards.boards[.init(originID: draft.outbound.originID)]?.arrivals.map(\.lineId) ?? []
        return Array(Set(known + live + draft.outbound.lineIDs + draft.returnLineIDs)).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                if savingFavourite {
                    Section("Favourite") {
                        TextField("Name (optional)", text: $draft.name)
                    }
                }
                Section {
                    Button { picker = .origin } label: {
                        LabeledContent("From", value: origin?.name ?? "Choose station or pier")
                    }
                    ForEach(draft.outbound.destinationIDs, id: \.self) { id in
                        HStack {
                            Text(appState.departureStop(id: id)?.name ?? id)
                            Spacer()
                            Button("Remove destination", systemImage: "minus.circle") {
                                draft.outbound.destinationIDs.removeAll { $0 == id }
                            }.labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(appState.departureStop(id: id)?.name ?? id)")
                        }
                    }
                    Button("Choose destinations", systemImage: "mappin.and.ellipse") { picker = .destinations }
                        .disabled(origin == nil)
                } header: { Text("Calling at") } footer: {
                    Text("Shows services calling at any selected stop, including intermediate stops. Leave empty for all departures. Return journeys are included automatically.")
                }
                Section {
                    serviceChoices(selection: $draft.outbound.lineIDs)
                    if !draft.outbound.destinationIDs.isEmpty {
                        DisclosureGroup("Return services") {
                            serviceChoices(selection: $draft.returnLineIDs)
                        }
                    }
                } header: { Text("Lines and operators") } footer: {
                    Text("All services combines available lines and operators. Operator choices appear after live departures load.")
                }
                if draft.manualOriginID != nil {
                    Section {
                        Button("Use location to choose direction") { draft.manualOriginID = nil }
                    }
                }
            }
            .navigationTitle(savingFavourite ? "Save departure board" : "Filter departures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.outbound = .init(originID: draft.outbound.originID,
                            destinationIDs: draft.outbound.destinationIDs, lineIDs: draft.outbound.lineIDs)
                        if !draft.endpointIDs.contains(draft.lastOriginID) { draft.lastOriginID = draft.outbound.originID }
                        if let manual = draft.manualOriginID, !draft.endpointIDs.contains(manual) { draft.manualOriginID = nil }
                        onSave(draft); dismiss()
                    }.disabled(origin == nil)
                }
            }
            .sheet(item: $picker) { selection in
                DepartureEndpointPicker(stops: appState.departureStops.filter {
                    selection == .origin || ($0.id != draft.outbound.originID && $0.mode == origin?.mode)
                }, selectedIDs: selection == .origin ? [draft.outbound.originID] : draft.outbound.destinationIDs,
                    multiple: selection == .destinations) { ids in
                    if selection == .origin, let id = ids.first {
                        draft.outbound.originID = id
                        draft.outbound.destinationIDs.removeAll { $0 == id || appState.departureStop(id: $0)?.mode != appState.departureStop(id: id)?.mode }
                        draft.outbound.lineIDs = []; draft.returnLineIDs = []
                        draft.lastOriginID = id; draft.manualOriginID = nil
                    } else { draft.outbound.destinationIDs = ids }
                }
            }
            .task(id: draft.outbound.originID) {
                guard origin != nil, !appState.isOffline else { return }
                await appState.departureBoards.refresh(.init(originID: draft.outbound.originID))
            }
            .onChange(of: draft.outbound.lineIDs) { old, new in
                if draft.returnLineIDs == old { draft.returnLineIDs = new }
            }
        }
    }

    private func serviceChoices(selection: Binding<[String]>) -> some View {
        Group {
            Button { selection.wrappedValue = [] } label: {
                HStack { Text("All services"); Spacer(); if selection.wrappedValue.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(lineChoices, id: \.self) { line in
                Button {
                    if selection.wrappedValue.contains(line) { selection.wrappedValue.removeAll { $0 == line } }
                    else { selection.wrappedValue.append(line) }
                } label: {
                    HStack { Text(DepartureBoardTheme.lineName(line)); Spacer()
                        if selection.wrappedValue.contains(line) { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }
}

struct DepartureEndpointPicker: View {
    @Environment(\.dismiss) private var dismiss
    let stops: [DepartureStop]
    @State var selectedIDs: [String]
    var multiple = false
    let onSelect: ([String]) -> Void
    @State private var query = ""
    private var results: [DepartureStop] {
        stops.filter { query.isEmpty || $0.name.localizedStandardContains(query)
            || $0.railCodes.contains { $0.localizedStandardContains(query) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                if multiple { Text("Choose up to 8 stops · \(selectedIDs.count) selected").foregroundStyle(.secondary) }
                ForEach(results) { stop in
                    Button {
                        if !multiple { onSelect([stop.id]); dismiss() }
                        else if selectedIDs.contains(stop.id) { selectedIDs.removeAll { $0 == stop.id } }
                        else if selectedIDs.count < 8 { selectedIDs.append(stop.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(stop.name)
                                Text(stop.mode == "river" ? "River Bus" : stop.railCodes.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedIDs.contains(stop.id) { Image(systemName: "checkmark") }
                        }
                    }.disabled(multiple && selectedIDs.count >= 8 && !selectedIDs.contains(stop.id))
                }
            }
            .searchable(text: $query, prompt: "Station or pier")
            .navigationTitle(multiple ? "Calling at" : "Choose origin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if multiple {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { onSelect(selectedIDs); dismiss() } }
                }
            }
        }
    }
}


struct DepartureDirectionFilterEditor: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var request: DepartureBoardRequest
    let onSave: (DepartureBoardRequest) -> Void
    @State private var showsStops = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(request.destinationIDs, id: \.self) { id in
                        HStack {
                            Text(appState.departureStop(id: id)?.name ?? id)
                            Spacer()
                            Button("Remove stop", systemImage: "minus.circle") {
                                request.destinationIDs.removeAll { $0 == id }
                            }.labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(appState.departureStop(id: id)?.name ?? id)")
                        }
                    }
                    Button("Choose calling points", systemImage: "mappin.and.ellipse") { showsStops = true }
                    Button("Show all departures") { request.destinationIDs = [] }
                        .disabled(request.destinationIDs.isEmpty)
                } header: { Text("Calling at") } footer: {
                    Text("Shows services calling at any selected stop. Leave empty for all departures in this direction. Other directions keep their own filters.")
                }
            }
            .navigationTitle("Filter \(request.direction ?? "departures")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(request); dismiss() } }
            }
            .sheet(isPresented: $showsStops) {
                DepartureEndpointPicker(stops: appState.departureStops.filter {
                    $0.id != request.originID && $0.mode == appState.departureStop(id: request.originID)?.mode
                }, selectedIDs: request.destinationIDs, multiple: true) { request.destinationIDs = $0 }
            }
        }
    }
}
