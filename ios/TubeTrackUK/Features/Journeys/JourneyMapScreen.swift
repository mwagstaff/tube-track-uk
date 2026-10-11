import SwiftUI
import MapKit

struct JourneyMapScreen: View {
    let journey: PlannedJourney

    var body: some View {
        if journey.legs.contains(where: { ["national-rail", "replacement-bus"].contains($0.mode) }) {
            CombinedJourneyMapScreen(journey: journey)
        } else {
            TfLJourneyMapScreen(journey: journey)
        }
    }
}

private struct CombinedJourneyMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    let journey: PlannedJourney
    @State private var geometry = JourneyGeographicGeometry()

    var body: some View {
        Map {
            ForEach(geometry.routes) { route in
                MapPolyline(coordinates: route.points.map(\.coordinate))
                    .stroke(.blue, lineWidth: 5)
            }
            ForEach(geometry.stations) { station in
                Marker(station.name, coordinate: station.coordinate)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start, end and change stations").font(.appHeadline())
                Text(geometry.stations.map(\.name).joined(separator: " → "))
                    .font(.appSubheadline())
                if geometry.unmappedLegCount > 0 {
                    Text("Some sections, walking links or replacement-bus roads are not drawn. Follow the full journey directions.")
                        .font(.appCaption()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(.regularMaterial)
        }
        .navigationTitle("Journey map")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: journey.id) {
            guard let graph = appState.graph else { return }
            let rail = NationalRailMap.bundled
            let resolved = await Task.detached(priority: .userInitiated) {
                JourneyGeographicGeometry.resolve(journey, graph: graph, rail: rail)
            }.value
            guard !Task.isCancelled else { return }
            geometry = resolved
        }
    }
}

private struct TfLJourneyMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    let journey: PlannedJourney
    // Keep this preview's camera and station selection independent of the Map tab.
    @State private var mapState = TubeAppState(monitorsConnectivity: false)
    @State private var document: BeckMapDocument?
    @State private var renderCache: BeckMapCanvas.RenderCache?
    @State private var highlight = JourneyMapHighlight()
    @State private var errorMessage: String?
    @State private var selectedStationName: String?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if let document, let renderCache {
                BeckMapCanvas(
                    document: document, renderCache: renderCache,
                    presentation: presentation,
                    disruptionIDsBySegmentID: [:], liveTrains: [], referenceOverlayVisible: false,
                    resetToken: 0, locationFocusRequest: nil, contentVerticalBias: 0,
                    onUserZoomIn: {}, onInteractionChange: { _ in }, stationSelectionGeneration: 0,
                    onStationTap: { id, _, _ in
                        selectedStationName = document.stationMarkers.first { $0.stationID == id }?.name
                    },
                    onDisruptionTap: { _ in }, onBackgroundTap: { selectedStationName = nil }
                )
                .environment(mapState)
            } else if let errorMessage {
                ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(errorMessage))
            } else {
                ProgressView("Loading journey map…")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedStationName { Text(selectedStationName).font(.appHeadline()) }
                if let first = journey.legs.first, let last = journey.legs.last {
                    Text("Start: \(first.from.name)").font(.appCaption(.semibold))
                    Text("End: \(last.to.name)").font(.appCaption(.semibold))
                }
                DisclosureGroup("Start, end and change stations") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let first = journey.legs.first { Text("Start: \(first.from.name)") }
                            ForEach(Array(journey.legs.dropLast().enumerated()), id: \.offset) { _, leg in
                                Text("Change: \(leg.to.name)")
                            }
                            if let last = journey.legs.last { Text("End: \(last.to.name)") }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }
                Text("Journey lines are shown in colour. Blue rings mark your stations.")
                    .font(.appCaption()).foregroundStyle(.secondary)
                if highlight.unmappedLegCount > 0 {
                    Text("Some journey sections could not be matched to this map. Follow the full directions in Journey details.")
                        .font(.appCaption()).foregroundStyle(.secondary)
                }
                if journey.legs.contains(where: { $0.mode == "walking" }) {
                    Text("Walking connections are listed in Journey details.")
                        .font(.appCaption()).foregroundStyle(.secondary)
                }
            }
            .font(.appSubheadline())
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Journey map")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: journey.id) {
            guard let graph = appState.graph else {
                errorMessage = "The network map could not be loaded."
                return
            }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try BeckMapRepository().load(region: .fullUnderground, graph: graph)
                }.value
                try Task.checkCancellation()
                let resolved = JourneyMapResolver(graph: graph, document: loaded).resolve(journey)
                let cache = await Task.detached(priority: .userInitiated) {
                    BeckMapCanvas.RenderCache(document: loaded, loadsDebugReference: false)
                }.value
                try Task.checkCancellation()
                mapState.graph = graph
                highlight = resolved
                renderCache = cache
                document = loaded
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "The network map could not be loaded. Please try again."
            }
        }
    }

    private var presentation: BeckMapPresentationSnapshot {
        BeckMapPresentationSnapshot(
            selectedLineID: nil, selectedStationID: nil,
            affectedSegmentIDs: highlight.segmentIDs, affectedStationIDs: highlight.stationIDs,
            disruptionDisplayMode: .issues, networkFilter: nil,
            networkFeaturedLineIDs: [], networkFeaturedSegmentIDs: [], networkSectionLineIDs: [],
            closedLineIDs: [], mobileCoverageMode: .off,
            mobileCoverageBySegmentID: [:], mobileCoverageByStationID: [:], stationOnlyCoverageStationIDs: [],
            highlightsJourney: true
        )
    }
}
