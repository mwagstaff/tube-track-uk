import MapKit
import SwiftUI

/// A value snapshot of everything the geographic `Map` draws.
///
/// Any SwiftUI update of a `Map` makes MapKit re-apply its configuration,
/// re-add overlays and re-measure every annotation view, which costs tens to
/// hundreds of milliseconds. `GeographicMapView` therefore only updates when
/// this snapshot (or its camera/selection inputs) actually changes, instead of
/// whenever any observed app state or parent chrome changes.
struct GeographicMapContent: Equatable {
    struct Route: Identifiable, Equatable {
        let id: String
        let overlay: MKPolyline
        let color: Color
        let lineWidth: CGFloat
        var dash: [CGFloat] = []

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.overlay === rhs.overlay && lhs.color == rhs.color
                && lhs.lineWidth == rhs.lineWidth && lhs.dash == rhs.dash
        }
    }

    struct Station: Identifiable, Equatable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let showsName: Bool
        let selected: Bool
        let opacity: Double
        let stationOnlyCoverage: Bool
        let accessibilityLabel: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct RiverSegment: Identifiable, Equatable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]

        /// Segment geometry is derived from the pier pair in its ID.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.coordinates.count == rhs.coordinates.count
        }
    }

    struct Pier: Identifiable, Equatable {
        let pier: RiverPier
        let showsName: Bool
        let selected: Bool

        var id: String { pier.id }
    }

    struct CableCar: Equatable {
        struct WalkingConnection: Equatable {
            let terminalLatitude: Double
            let terminalLongitude: Double
            let stationLatitude: Double
            let stationLongitude: Double
        }

        let route: [CLLocationCoordinate2D]
        let terminals: [CableCarTerminal]
        let selectedTerminalID: String?
        let showsTerminalNames: Bool
        let presentation: CableCarPresentation
        let walkingConnection: WalkingConnection?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.terminals == rhs.terminals
                && lhs.selectedTerminalID == rhs.selectedTerminalID
                && lhs.showsTerminalNames == rhs.showsTerminalNames
                && lhs.presentation == rhs.presentation
                && lhs.walkingConnection == rhs.walkingConnection
                && lhs.route.count == rhs.route.count
                && zip(lhs.route, rhs.route).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    var routes: [Route] = []
    var stations: [Station] = []
    var riverSegments: [RiverSegment] = []
    var piers: [Pier] = []
    var cableCar: CableCar?
    var markerDiameter: CGFloat = 5
    var expandedSymbols = false
}

struct GeographicMapView: View {
    @Environment(TubeAppState.self) private var appState

    let content: GeographicMapContent
    /// A snapshot of the bound selection. A binding reads its current value,
    /// so comparing bindings would always succeed.
    let selectionValue: String?
    /// Camera moves reach the Map through the binding alone: the Map reads it
    /// directly, and re-evaluating this view for every animated camera frame
    /// would also rebuild the Map content.
    @Binding var position: MapCameraPosition
    @Binding var selection: String?
    let scope: Namespace.ID
    /// Captured by `onCameraChange`; compared so a new graph or viewport size
    /// always replaces the callback.
    let graphID: String
    let viewportSize: CGSize
    let camera: GeographicCameraState
    let reduceMotion: Bool
    let onCameraChange: (MapCameraUpdateContext) -> Void
    let onCameraChangeEnd: (MapCameraUpdateContext) -> Void

    /// A stable style value. Building a new style in every body pass makes
    /// MapKit reapply its cartographic configuration on each content update.
    private static let mapStyle = MapStyle.standard(
        elevation: .flat,
        pointsOfInterest: .excludingAll,
        showsTraffic: false
    )

    var body: some View {
        Map(position: $position, selection: $selection, scope: scope) {
            ForEach(content.routes) { route in
                MapPolyline(route.overlay)
                    .stroke(
                        route.color,
                        style: StrokeStyle(
                            lineWidth: route.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: route.dash
                        )
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
            
            ForEach(content.stations) { station in
                Annotation(
                    station.showsName ? station.name : "",
                    coordinate: station.coordinate,
                    anchor: .center
                ) {
                    GeographicStationMarker(
                        station: station,
                        markerDiameter: content.markerDiameter
                    )
                }
                .tag(station.id)
            }

            ForEach(content.riverSegments) { segment in
                MapPolyline(coordinates: segment.coordinates).stroke(.blue.opacity(0.65), lineWidth: 3)
            }
            ForEach(content.piers) { item in
                Annotation(item.showsName ? item.pier.name : "",
                           coordinate: item.pier.coordinate, anchor: .center) {
                    RiverPierSymbol(selected: item.selected,
                        expanded: content.expandedSymbols,
                        compactDiameter: content.markerDiameter)
                        .accessibilityLabel("\(item.pier.name), River Bus departures")
                }.tag("pier:\(item.pier.id)")
            }

            if let cable = content.cableCar {
                MapPolyline(coordinates: cable.route)
                    .stroke(Color(.systemBackground), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                MapPolyline(coordinates: cable.route)
                    .stroke(cable.presentation.routeTint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                MapPolyline(coordinates: cable.route)
                    .stroke(Color(.systemBackground), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ForEach(cable.terminals) { terminal in
                    Annotation(cable.showsTerminalNames ? terminal.name : "", coordinate: terminal.coordinate) {
                        CableCarTerminalSymbol(selected: cable.selectedTerminalID == terminal.id, tint: .red,
                            expanded: content.expandedSymbols,
                            compactDiameter: content.markerDiameter)
                            .accessibilityLabel("\(terminal.name), cable car, \(cable.presentation.headline)")
                    }.tag("cable:\(terminal.id)")
                }
                if cable.presentation.kind != .open {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: 51.50365, longitude: 0.013)) {
                        Button { appState.selectCableCar() } label: {
                            CableCarMapBadge(presentation: cable.presentation)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let walk = cable.walkingConnection {
                    let terminal = CLLocationCoordinate2D(latitude: walk.terminalLatitude, longitude: walk.terminalLongitude)
                    let station = CLLocationCoordinate2D(latitude: walk.stationLatitude, longitude: walk.stationLongitude)
                    MapPolyline(coordinates: [terminal, station])
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                    Annotation("Walking connection", coordinate: CLLocationCoordinate2D(
                        latitude: (terminal.latitude + station.latitude) / 2,
                        longitude: (terminal.longitude + station.longitude) / 2
                    )) {
                        Image(systemName: "figure.walk").padding(4).background(Color(.systemBackground), in: .circle)
                    }
                }
            }

            UserAnnotation {
                GeographicUserLocationAnnotation(camera: camera, reduceMotion: reduceMotion)
                .frame(width: 76, height: 76)
                .allowsHitTesting(false)
                .accessibilityLabel("Your location")
            }
        }
        .mapStyle(Self.mapStyle)
        // The compass and scale are drawn by the parent in the same map scope,
        // so fading them during a gesture never updates the Map itself.
        .mapControls {}
        .onMapCameraChange(frequency: .continuous, onCameraChange)
        .onMapCameraChange(frequency: .onEnd, onCameraChangeEnd)
    }
}

/// Only value inputs are compared. The bindings and callbacks otherwise reach
/// only the parent's state storage, so a retained older copy stays correct.
extension GeographicMapView: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
            && lhs.selectionValue == rhs.selectionValue
            && lhs.scope == rhs.scope
            && lhs.graphID == rhs.graphID
            && lhs.viewportSize == rhs.viewportSize
            && lhs.camera === rhs.camera
            && lhs.reduceMotion == rhs.reduceMotion
    }
}

/// Reads the heading here, so rotating the map updates only this marker
/// rather than the Map's content.
private struct GeographicUserLocationAnnotation: View {
    let camera: GeographicCameraState
    let reduceMotion: Bool

    var body: some View {
        GeographicMapUserLocationMarker(
            mapHeading: camera.heading,
            reduceMotion: reduceMotion
        )
    }
}

private struct GeographicStationMarker: View {
    let station: GeographicMapContent.Station
    let markerDiameter: CGFloat

    var body: some View {
        let selected = station.selected
        ZStack {
            if selected {
                Circle()
                    .fill(Color.blue.opacity(0.16))
                    .stroke(Color.blue.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 32, height: 32)
                    .shadow(color: Color.blue.opacity(0.35), radius: 6)
            }

            Circle()
                .fill(.background)
                .stroke(
                    selected ? Color.blue : Color.primary,
                    lineWidth: selected ? 3 : (markerDiameter < 8 ? 1.25 : 2)
                )
                .frame(
                    width: selected ? 18 : markerDiameter,
                    height: selected ? 18 : markerDiameter
                )

            if station.stationOnlyCoverage {
                Image(systemName: "cellularbars")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Color.green, in: .circle)
                    .overlay {
                        Circle().stroke(.white, lineWidth: 1)
                    }
                    .offset(x: 9, y: -9)
            }
        }
        .opacity(station.opacity)
        .animation(.smooth(duration: 0.3), value: selected)
        .accessibilityLabel(station.accessibilityLabel)
    }
}
