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
                    ForEach(Array(draft.outbound.destinationIDs.prefix(1)), id: \.self) { id in
                        HStack {
                            Text(appState.departureStop(id: id)?.name ?? id)
                            Spacer()
                            Button("Remove destination", systemImage: "minus.circle") {
                                draft.outbound.destinationIDs = []
                            }.labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(appState.departureStop(id: id)?.name ?? id)")
                        }
                    }
                    Button("Choose destination", systemImage: "mappin.and.ellipse") { picker = .destinations }
                        .disabled(origin == nil)
                } header: { Text("Calling at") } footer: {
                    Text("Shows services calling at your selected destination, including intermediate stops. Leave empty for all departures. Return journeys are included automatically.")
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
            .navigationTitle(savingFavourite ? "Save departure board" : "Calling at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.outbound = .init(originID: draft.outbound.originID,
                            destinationIDs: Array(draft.outbound.destinationIDs.prefix(1)), lineIDs: draft.outbound.lineIDs)
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
                    title: selection == .destinations ? "Calling at" : "Starting station") { ids in
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
    let stops: [DepartureStop]
    let selectedIDs: [String]
    var title = "Choose origin"
    let onSelect: ([String]) -> Void

    var body: some View {
        StationPickerSheet(title: title, selectedID: selectedIDs.first,
                           selectionHint: "Selects this station", searchPrompt: stops.contains { $0.mode == "river" } ? "Station or pier" : "Station name",
                           results: { query in
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let matches = stops.filter { stop in
                let searchable = ([stop.name] + stop.railCodes).joined(separator: " ")
                return tokens.allSatisfy { searchable.localizedStandardContains($0) }
            }.sorted {
                let lhs = $0.name.lowercased().hasPrefix(query.lowercased())
                let rhs = $1.name.lowercased().hasPrefix(query.lowercased())
                if lhs != rhs { return lhs }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (query.isEmpty ? matches : Array(matches.prefix(40))).map { stop in
                StationPickerEntry(id: stop.id, name: stop.name,
                    lineIDs: stop.lineIDs.compactMap(TubeLineID.init(rawValue:)).sorted { $0.displayName < $1.displayName },
                    subtitle: stop.mode == "river" ? "River Bus" : (stop.railCodes.isEmpty ? nil : "National Rail"))
            }
        }, onSelect: { onSelect([$0.id]) })
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
                    ForEach(Array(request.destinationIDs.prefix(1)), id: \.self) { id in
                        HStack {
                            Text(appState.departureStop(id: id)?.name ?? id)
                            Spacer()
                            Button("Remove stop", systemImage: "minus.circle") {
                                request.destinationIDs = []
                            }.labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(appState.departureStop(id: id)?.name ?? id)")
                        }
                    }
                    Button("Choose destination", systemImage: "mappin.and.ellipse") { showsStops = true }
                    Button("Show all departures") { request.destinationIDs = [] }
                        .disabled(request.destinationIDs.isEmpty)
                } header: { Text("Calling at") } footer: {
                    Text("Shows services calling at your selected destination. Leave empty for all departures in this direction. Other directions keep their own filters.")
                }
            }
            .navigationTitle("Calling at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        request.destinationIDs = Array(request.destinationIDs.prefix(1))
                        onSave(request); dismiss()
                    } }
            }
            .sheet(isPresented: $showsStops) {
                DepartureEndpointPicker(stops: appState.departureStops.filter {
                    $0.id != request.originID && $0.mode == appState.departureStop(id: request.originID)?.mode
                }, selectedIDs: request.destinationIDs, title: "Calling at") { request.destinationIDs = $0 }
            }
        }
    }
}

#Preview("Calling at · Dark, large text") {
    DepartureEndpointPicker(stops: DepartureStop.bundled, selectedIDs: [], title: "Calling at") { _ in }
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
