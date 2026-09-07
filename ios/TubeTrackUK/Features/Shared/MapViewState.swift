import CoreGraphics
import MapKit
import SwiftUI

enum MapPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case beck
    case realWorld

    var id: Self { self }

    var title: String {
        switch self {
        case .beck: "Tube map"
        case .realWorld: "Real world"
        }
    }

    var symbol: String {
        switch self {
        case .beck: "map.fill"
        case .realWorld: "globe.europe.africa.fill"
        }
    }

    var toggled: Self {
        self == .beck ? .realWorld : .beck
    }

    var switchActionTitle: String {
        switch toggled {
        case .beck: "Show line view"
        case .realWorld: "Show map view"
        }
    }

    var switchActionSymbol: String {
        toggled.symbol
    }

    var toggleNoticeMessage: String {
        switch self {
        case .beck: "Toggling network view"
        case .realWorld: "Toggling map view"
        }
    }
}

enum MapNetworkStatFilter: String, CaseIterable, Identifiable, Sendable {
    case lines
    case goodService
    case minorDelays
    case majorIssues
    case closed
    case disrupted

    var id: Self { self }

    var title: String {
        switch self {
        case .lines: "Lines"
        case .goodService: "Good service"
        case .minorDelays: "Minor delays"
        case .majorIssues: "Major issues"
        case .closed: "Closed"
        case .disrupted: "Disrupted"
        }
    }

    var symbol: String {
        switch self {
        case .lines: "tram.fill"
        case .goodService: "circle.fill"
        case .minorDelays: "circle.fill"
        case .majorIssues: "circle.fill"
        case .closed: "minus.circle.fill"
        case .disrupted: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .lines: .tubeBlue
        case .goodService: .green
        case .minorDelays: .orange
        case .majorIssues: .red
        case .closed: .gray
        case .disrupted: .red
        }
    }

    var representsDisruptedLines: Bool {
        switch self {
        case .minorDelays, .majorIssues, .closed, .disrupted:
            true
        case .lines, .goodService:
            false
        }
    }
}

enum MapDisruptionHighlightScope: Equatable, Sendable {
    case all
    case major
    case minor

    init?(filter: MapNetworkStatFilter?) {
        switch filter {
        case .disrupted:
            self = .all
        case .majorIssues:
            self = .major
        case .minorDelays:
            self = .minor
        default:
            return nil
        }
    }

    var filter: MapNetworkStatFilter {
        switch self {
        case .all: .disrupted
        case .major: .majorIssues
        case .minor: .minorDelays
        }
    }

    var next: Self? {
        switch self {
        case .all: .major
        case .major: .minor
        case .minor: nil
        }
    }

    var noticeMessage: String {
        switch self {
        case .all: "Showing all disruptions"
        case .major: "Showing major disruptions only"
        case .minor: "Showing minor disruptions only"
        }
    }

    func includes(_ disruption: ResolvedDisruption) -> Bool {
        switch self {
        case .all: true
        case .major: disruption.isMajorIssue
        case .minor: disruption.isMinorDelay
        }
    }
}

struct MapNetworkStatusSummary: Equatable, Sendable {
    let lineIDs: Set<TubeLineID>
    let goodServiceLineIDs: Set<TubeLineID>
    let minorDelayLineIDs: Set<TubeLineID>
    let majorIssueLineIDs: Set<TubeLineID>
    let closedLineIDs: Set<TubeLineID>
    let disruptedLineIDs: Set<TubeLineID>

    init(
        statuses: [TfLLineStatus],
        disruptions: [ResolvedDisruption],
        isViewingLiveStatus: Bool = true
    ) {
        let allLineIDs = Set(TubeLineID.allCases)
        let disrupted = Set(disruptions.map(\.lineID))
        let networkStatuses = statuses.filter { TubeLineID.allCases.contains($0.id) }
        let liveClosed = LineServiceClosurePolicy.closedLineIDs(in: networkStatuses)
        let reportedMinorDelays: Set<TubeLineID> = Set(networkStatuses.compactMap { line in
            line.lineStatuses.contains { $0.statusSeverity == 9 } ? line.id : nil
        })
        let liveGoodService: Set<TubeLineID> = Set(networkStatuses.compactMap { line in
            guard !liveClosed.contains(line.id), !line.lineStatuses.isEmpty,
                  line.lineStatuses.allSatisfy(\.isGoodService) else { return nil }
            return line.id
        })
        let reportedMajorIssues = Set(
            disruptions.lazy.filter(\.isMajorIssue).map(\.lineID)
        )
        // TfL can report different severities for separate sections of one line.
        // Keep the summary cards mutually exclusive by assigning each line to its
        // highest-priority bucket: closed, then major, then minor.
        let liveMajorIssues = reportedMajorIssues.subtracting(liveClosed)
        let liveMinorDelays = reportedMinorDelays
            .subtracting(liveClosed)
            .subtracting(reportedMajorIssues)

        lineIDs = allLineIDs
        goodServiceLineIDs = isViewingLiveStatus
            ? liveGoodService
            : allLineIDs.subtracting(disrupted)
        minorDelayLineIDs = isViewingLiveStatus ? liveMinorDelays : []
        majorIssueLineIDs = isViewingLiveStatus ? liveMajorIssues : []
        closedLineIDs = isViewingLiveStatus ? liveClosed : []
        disruptedLineIDs = disrupted
    }

    func lineIDs(for filter: MapNetworkStatFilter) -> Set<TubeLineID> {
        switch filter {
        case .lines: lineIDs
        case .goodService: goodServiceLineIDs
        case .minorDelays: minorDelayLineIDs
        case .majorIssues: majorIssueLineIDs
        case .closed: closedLineIDs
        case .disrupted: disruptedLineIDs
        }
    }

    func count(for filter: MapNetworkStatFilter) -> Int {
        lineIDs(for: filter).count
    }
}

struct MapDisruptionLineGroups: Equatable, Sendable {
    let majorIssues: [ResolvedDisruption]
    let minorDelays: [ResolvedDisruption]

    init(disruptions: [ResolvedDisruption]) {
        let representatives = Dictionary(grouping: disruptions, by: \.lineID)
            .values
            .compactMap { disruptions -> ResolvedDisruption? in
                let ordered = disruptions.sorted {
                    if $0.severity != $1.severity { return $0.severity < $1.severity }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return ordered.first(where: \.isMajorIssue) ?? ordered.first
            }

        majorIssues = representatives
            .filter(\.isMajorIssue)
            .sorted(by: Self.sortByLineName)
        minorDelays = representatives
            .filter(\.isMinorDelay)
            .sorted(by: Self.sortByLineName)
    }

    var all: [ResolvedDisruption] {
        majorIssues + minorDelays
    }

    private static func sortByLineName(
        _ left: ResolvedDisruption,
        _ right: ResolvedDisruption
    ) -> Bool {
        left.lineID.displayName.localizedStandardCompare(right.lineID.displayName)
            == .orderedAscending
    }
}

enum MapNetworkRouteStyling {
    static func mutesSegment(
        lineID: TubeLineID,
        isAffected: Bool,
        isFeaturedSection: Bool,
        selectedFilter: MapNetworkStatFilter?,
        featuredLineIDs: Set<TubeLineID>,
        sectionLineIDs: Set<TubeLineID>,
        closedLineIDs: Set<TubeLineID>,
        disruptionDisplayMode: DisruptionDisplayMode
    ) -> Bool {
        if let selectedFilter {
            switch selectedFilter {
            case .lines:
                return false
            case .minorDelays, .majorIssues, .disrupted:
                guard featuredLineIDs.contains(lineID) else { return true }
                guard sectionLineIDs.contains(lineID) else { return false }
                return !isFeaturedSection
            case .goodService, .closed:
                return !featuredLineIDs.contains(lineID)
            }
        }
        if closedLineIDs.contains(lineID) { return true }
        return disruptionDisplayMode.mutesSegment(isAffected: isAffected)
    }
}

struct MapDisruptionFocus: Equatable, Sendable {
    let lineIDs: Set<TubeLineID>
    let segmentIDs: Set<String>
    let stationIDs: Set<String>
    let confidence: ResolutionConfidence

    init(disruption: ResolvedDisruption, graph: TubeGraph?) {
        lineIDs = [disruption.lineID]

        guard let graph else {
            segmentIDs = disruption.affectedSegmentIDs
            stationIDs = disruption.affectedStationIDs
            confidence = disruption.confidence
            return
        }

        let matchingSegmentIDs = Set(disruption.affectedSegmentIDs.filter {
            graph.segmentsByID[$0]?.lineID == disruption.lineID
        })
        let fallsBackToWholeLine = matchingSegmentIDs.isEmpty
        let focusedSegmentIDs = fallsBackToWholeLine
            ? Set(graph.segments(for: disruption.lineID).map(\.id))
            : matchingSegmentIDs
        let segmentStationIDs = Set(focusedSegmentIDs.flatMap { segmentID -> [String] in
            guard let segment = graph.segmentsByID[segmentID] else { return [] }
            return [segment.fromStationID, segment.toStationID]
        })
        let matchingAffectedStationIDs = Set(disruption.affectedStationIDs.filter {
            graph.stationsByID[$0]?.lineIDs.contains(disruption.lineID) == true
        })

        segmentIDs = focusedSegmentIDs
        stationIDs = segmentStationIDs.union(matchingAffectedStationIDs)
        confidence = fallsBackToWholeLine ? .lineOnly : disruption.confidence
    }
}

struct SharedMapViewport: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// The geographic footprint is the source of truth for camera scale.
    /// `zoom` remains a convenient derived value for marker styling.
    var mapPointWidth: Double
    var mapPointHeight: Double
    var zoom: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var visibleMapRect: MKMapRect {
        let centre = MKMapPoint(coordinate)
        return MKMapRect(
            x: centre.x - mapPointWidth / 2,
            y: centre.y - mapPointHeight / 2,
            width: mapPointWidth,
            height: mapPointHeight
        )
    }

    init(
        coordinate: CLLocationCoordinate2D,
        visibleMapRect: MKMapRect,
        zoom: Double
    ) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        mapPointWidth = max(1, visibleMapRect.width)
        mapPointHeight = max(1, visibleMapRect.height)
        self.zoom = max(0.2, min(24, zoom))
    }
}

struct MapLocationFocusRequest: Equatable, Sendable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let snappedStationID: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum TrainMapFocusPolicy {
    static let geographicLatitudeDelta = 0.025
    static let geographicLongitudeDelta = 0.04
    static let schematicFocusScale: CGFloat = 1.65

    static func geographicRegion(
        centeredAt coordinate: CLLocationCoordinate2D,
        currentSpan: MKCoordinateSpan
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: min(
                    currentSpan.latitudeDelta,
                    geographicLatitudeDelta
                ),
                longitudeDelta: min(
                    currentSpan.longitudeDelta,
                    geographicLongitudeDelta
                )
            )
        )
    }

    static func schematicScale(
        currentScale: CGFloat,
        minimumScale: CGFloat,
        maximumScale: CGFloat
    ) -> CGFloat {
        min(
            maximumScale,
            max(currentScale, max(minimumScale, schematicFocusScale))
        )
    }

    static func schematicAnchor(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * 0.56)
    }
}

enum MapLocationFocusPolicy {
    static func request(
        for location: CLLocation,
        in graph: TubeGraph,
        id: Int
    ) -> MapLocationFocusRequest? {
        let coordinate = location.coordinate
        let networkBounds = SharedMapProjection.geographicBounds(for: graph)
        if networkBounds.contains(MKMapPoint(coordinate)) {
            return MapLocationFocusRequest(
                id: id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                snappedStationID: nil
            )
        }

        guard let nearestStation = NearbyStationFinder.nearestStations(
            to: location,
            in: graph.stations,
            limit: 1
        ).first?.station else { return nil }
        return MapLocationFocusRequest(
            id: id,
            latitude: nearestStation.latitude,
            longitude: nearestStation.longitude,
            snappedStationID: nearestStation.id
        )
    }
}

struct BeckMapCameraSnapshot: Equatable, Sendable {
    let scale: Double
    let fittedScale: Double
    let offsetX: Double
    let offsetY: Double
    let viewportWidth: Double
    let viewportHeight: Double

    func screenPoint(for artworkPoint: CGPoint, in size: CGSize) -> CGPoint {
        let xScale = size.width / max(1, viewportWidth)
        let yScale = size.height / max(1, viewportHeight)
        return CGPoint(
            x: (artworkPoint.x * scale + offsetX) * xScale,
            y: (artworkPoint.y * scale + offsetY) * yScale
        )
    }
}

enum SharedMapProjection {
    static func geographicBounds(for graph: TubeGraph) -> MKMapRect {
        let points = graph.stations.map { MKMapPoint($0.coordinate) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return MKMapRect.world
        }
        let width = max(1, maxX - minX)
        let height = max(1, maxY - minY)
        return MKMapRect(
            x: minX - width * 0.08,
            y: minY - height * 0.08,
            width: width * 1.16,
            height: height * 1.16
        )
    }

    static func fittedGeographicRect(for graph: TubeGraph, size: CGSize) -> MKMapRect {
        let bounds = geographicBounds(for: graph)
        let aspect = max(0.1, Double(size.width / max(1, size.height)))
        let boundsAspect = bounds.width / max(1, bounds.height)
        if boundsAspect > aspect {
            let height = bounds.width / aspect
            return MKMapRect(
                x: bounds.minX,
                y: bounds.midY - height / 2,
                width: bounds.width,
                height: height
            )
        }
        let width = bounds.height * aspect
        return MKMapRect(
            x: bounds.midX - width / 2,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    static func geographicRect(
        for viewport: SharedMapViewport,
        graph: TubeGraph,
        size: CGSize
    ) -> MKMapRect {
        aspectFittedMapRect(viewport.visibleMapRect, size: size)
    }

    static func viewport(
        from rect: MKMapRect,
        graph: TubeGraph,
        size: CGSize
    ) -> SharedMapViewport {
        let visibleRect = aspectFittedMapRect(rect, size: size)
        let fitted = fittedGeographicRect(for: graph, size: size)
        let zoom = min(
            fitted.width / max(1, visibleRect.width),
            fitted.height / max(1, visibleRect.height)
        )
        return SharedMapViewport(
            coordinate: MKMapPoint(x: visibleRect.midX, y: visibleRect.midY).coordinate,
            visibleMapRect: visibleRect,
            zoom: zoom
        )
    }

    static func viewport(
        fromArtworkRect artworkRect: CGRect,
        document: BeckMapDocument,
        graph: TubeGraph,
        size: CGSize
    ) -> SharedMapViewport? {
        let artworkCentre = CGPoint(x: artworkRect.midX, y: artworkRect.midY)
        guard let centreCoordinate = coordinate(
            for: artworkCentre,
            document: document,
            graph: graph
        ), let mapPointsPerArtworkPoint = localMapPointsPerArtworkPoint(
            around: artworkCentre,
            document: document,
            graph: graph
        ) else { return nil }

        let centre = MKMapPoint(centreCoordinate)
        let visibleRect = aspectFittedMapRect(
            MKMapRect(
                x: centre.x - Double(artworkRect.width) * mapPointsPerArtworkPoint / 2,
                y: centre.y - Double(artworkRect.height) * mapPointsPerArtworkPoint / 2,
                width: Double(artworkRect.width) * mapPointsPerArtworkPoint,
                height: Double(artworkRect.height) * mapPointsPerArtworkPoint
            ),
            size: size
        )
        return viewport(from: visibleRect, graph: graph, size: size)
    }

    static func artworkRect(
        for viewport: SharedMapViewport,
        document: BeckMapDocument,
        graph: TubeGraph,
        size: CGSize
    ) -> CGRect? {
        let geographicRect = geographicRect(for: viewport, graph: graph, size: size)
        guard let centre = artworkPoint(
            for: viewport.coordinate,
            document: document,
            graph: graph
        ), let mapPointsPerArtworkPoint = localMapPointsPerArtworkPoint(
            around: centre,
            document: document,
            graph: graph
        ) else { return nil }

        let width = CGFloat(geographicRect.width / mapPointsPerArtworkPoint)
        let height = CGFloat(geographicRect.height / mapPointsPerArtworkPoint)
        return CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
    }

    static func screenPoint(
        for coordinate: CLLocationCoordinate2D,
        in rect: MKMapRect,
        size: CGSize
    ) -> CGPoint {
        let point = MKMapPoint(coordinate)
        return CGPoint(
            x: (point.x - rect.minX) / max(1, rect.width) * size.width,
            y: (point.y - rect.minY) / max(1, rect.height) * size.height
        )
    }

    private static func aspectFittedMapRect(_ rect: MKMapRect, size: CGSize) -> MKMapRect {
        let aspect = max(0.1, Double(size.width / max(1, size.height)))
        var width = max(1, rect.width)
        var height = max(1, rect.height)
        if width / height > aspect {
            height = width / aspect
        } else {
            width = height * aspect
        }
        return MKMapRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func artworkPoint(
        for coordinate: CLLocationCoordinate2D,
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> CGPoint? {
        let stations = pairedStations(document: document, graph: graph)
        let query = MKMapPoint(coordinate)
        return weightedValue(
            query: CGPoint(x: query.x, y: query.y),
            candidates: stations.map {
                (
                    source: CGPoint(x: $0.mapPoint.x, y: $0.mapPoint.y),
                    target: $0.artworkPoint
                )
            }
        )
    }

    static func coordinate(
        for artworkPoint: CGPoint,
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> CLLocationCoordinate2D? {
        let stations = pairedStations(document: document, graph: graph)
        guard let point = weightedValue(
            query: artworkPoint,
            candidates: stations.map {
                (
                    source: $0.artworkPoint,
                    target: CGPoint(x: $0.mapPoint.x, y: $0.mapPoint.y)
                )
            }
        ) else { return nil }
        return MKMapPoint(x: point.x, y: point.y).coordinate
    }

    private static func pairedStations(
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> [(stationID: String, artworkPoint: CGPoint, mapPoint: MKMapPoint)] {
        let stations = graph.stationsByID
        return document.stationMarkers.compactMap { marker -> (
            stationID: String,
            artworkPoint: CGPoint,
            mapPoint: MKMapPoint
        )? in
            guard let station = stations[marker.stationID] else { return nil }
            return (
                marker.stationID,
                CGPoint(x: marker.anchor.x, y: marker.anchor.y),
                MKMapPoint(station.coordinate)
            )
        }
    }

    /// Converts visual scale using the authored spacing of nearby connected
    /// stations. This avoids distant anchors in schematic whitespace making a
    /// tightly zoomed local view appear zoomed out on the geographic map.
    private static func localMapPointsPerArtworkPoint(
        around artworkPoint: CGPoint,
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> Double? {
        let nearbyStations = pairedStations(document: document, graph: graph)
            .sorted {
                hypot($0.artworkPoint.x - artworkPoint.x, $0.artworkPoint.y - artworkPoint.y)
                    < hypot($1.artworkPoint.x - artworkPoint.x, $1.artworkPoint.y - artworkPoint.y)
            }
            .prefix(12)
        let nearbyByID = nearbyStations.reduce(into: [:]) { result, station in
            result[station.stationID] = station
        }
        var ratios = graph.segments.compactMap { segment -> Double? in
            guard let start = nearbyByID[segment.fromStationID],
                  let end = nearbyByID[segment.toStationID] else { return nil }
            let artworkDistance = hypot(
                start.artworkPoint.x - end.artworkPoint.x,
                start.artworkPoint.y - end.artworkPoint.y
            )
            guard artworkDistance > 1 else { return nil }
            let mapDistance = hypot(
                start.mapPoint.x - end.mapPoint.x,
                start.mapPoint.y - end.mapPoint.y
            )
            return mapDistance / Double(artworkDistance)
        }
        .filter { $0.isFinite && $0 > 0 }
        .sorted()

        if ratios.isEmpty {
            let stations = Array(nearbyStations)
            ratios = stations.indices.flatMap { startIndex in
                stations.indices.dropFirst(startIndex + 1).compactMap { endIndex -> Double? in
                    let start = stations[startIndex]
                    let end = stations[endIndex]
                    let artworkDistance = hypot(
                        start.artworkPoint.x - end.artworkPoint.x,
                        start.artworkPoint.y - end.artworkPoint.y
                    )
                    guard artworkDistance > 1 else { return nil }
                    return hypot(
                        start.mapPoint.x - end.mapPoint.x,
                        start.mapPoint.y - end.mapPoint.y
                    ) / Double(artworkDistance)
                }
            }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        }
        guard !ratios.isEmpty else { return nil }
        return ratios[ratios.count / 2]
    }

    /// Smoothly maps between two differently distorted layouts by blending
    /// the four nearest authored station anchors. Exact station centres remain exact.
    private static func weightedValue(
        query: CGPoint,
        candidates: [(source: CGPoint, target: CGPoint)]
    ) -> CGPoint? {
        let nearest = candidates
            .map { candidate in
                (
                    candidate: candidate,
                    distance: hypot(candidate.source.x - query.x, candidate.source.y - query.y)
                )
            }
            .sorted { $0.distance < $1.distance }
            .prefix(4)
        guard let first = nearest.first else { return nil }
        if first.distance < 0.001 { return first.candidate.target }

        var totalWeight: CGFloat = 0
        var targetX: CGFloat = 0
        var targetY: CGFloat = 0
        for item in nearest {
            let weight = 1 / max(0.001, item.distance * item.distance)
            totalWeight += weight
            targetX += item.candidate.target.x * weight
            targetY += item.candidate.target.y * weight
        }
        guard totalWeight > 0 else { return nil }
        return CGPoint(x: targetX / totalWeight, y: targetY / totalWeight)
    }
}
