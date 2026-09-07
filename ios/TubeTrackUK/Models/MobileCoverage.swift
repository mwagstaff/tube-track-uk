import Foundation

enum MobileCoverageMode: String, CaseIterable, Sendable {
    case off
    case allUsable
    case undergroundOnly

    var next: Self {
        switch self {
        case .off: .allUsable
        case .allUsable: .undergroundOnly
        case .undergroundOnly: .off
        }
    }

    var isActive: Bool { self != .off }

    var title: String {
        switch self {
        case .off: "Off"
        case .allUsable: "All usable coverage"
        case .undergroundOnly: "Underground coverage only"
        }
    }

    var noticeMessage: String {
        switch self {
        case .off: "Showing all lines"
        case .allUsable: "Showing all mobile coverage"
        case .undergroundOnly: "Showing underground mobile coverage"
        }
    }
}

enum MobileCoverageAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
    case outOfScope
}

struct MobileCoverageDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let publishedAt: String
    let sourceURL: String
    let graphGeneratedAt: String
    let verifiedLineIDs: Set<TubeLineID>
    let belowGroundSegmentIDs: Set<String>
    let coveredTunnelSegmentIDs: Set<String>
    let belowGroundStationIDs: Set<String>
    let coveredStationIDs: Set<String>
}

struct MobileCoverageSnapshot: Equatable, Sendable {
    let identifier: String
    let publishedAt: String
    let sourceURL: String
    let verifiedLineIDs: Set<TubeLineID>
    let belowGroundSegmentIDs: Set<String>
    let coveredTunnelSegmentIDs: Set<String>
    let belowGroundStationIDs: Set<String>
    let coveredStationIDs: Set<String>
    let stationOnlyCoverageStationIDs: Set<String>
    private let verifiedBelowGroundStationIDs: Set<String>

    init(document: MobileCoverageDocument, graph: TubeGraph) throws {
        guard document.schemaVersion == 1 else {
            throw MobileCoverageRepositoryError.unsupportedSchema(document.schemaVersion)
        }
        guard document.graphGeneratedAt == graph.generatedAt else {
            throw MobileCoverageRepositoryError.graphMismatch(
                expected: graph.generatedAt,
                actual: document.graphGeneratedAt
            )
        }

        let segmentIDs = Set(graph.segments.map(\.id))
        let stationIDs = Set(graph.stations.map(\.id))
        let unknownSegments = document.belowGroundSegmentIDs
            .union(document.coveredTunnelSegmentIDs)
            .subtracting(segmentIDs)
        guard unknownSegments.isEmpty else {
            throw MobileCoverageRepositoryError.unknownSegmentIDs(unknownSegments.sorted())
        }
        let unknownStations = document.belowGroundStationIDs
            .union(document.coveredStationIDs)
            .subtracting(stationIDs)
        guard unknownStations.isEmpty else {
            throw MobileCoverageRepositoryError.unknownStationIDs(unknownStations.sorted())
        }
        guard document.coveredTunnelSegmentIDs.isSubset(
            of: document.belowGroundSegmentIDs
        ) else {
            throw MobileCoverageRepositoryError.coveredTunnelIsNotBelowGround
        }

        let expandedCoveredStations = Self.expandedHubStationIDs(
            document.coveredStationIDs,
            graph: graph
        )
        let expandedBelowGroundStations = Self.expandedHubStationIDs(
            document.belowGroundStationIDs,
            graph: graph
        )
        let coveredTunnelStationIDs = Set(
            graph.segments
                .filter { document.coveredTunnelSegmentIDs.contains($0.id) }
                .flatMap { [$0.fromStationID, $0.toStationID] }
        )
        let expandedCoveredTunnelStations = Self.expandedHubStationIDs(
            coveredTunnelStationIDs,
            graph: graph
        )
        let verifiedStationIDs = Set(
            graph.segments
                .filter {
                    document.belowGroundSegmentIDs.contains($0.id)
                        && document.verifiedLineIDs.contains($0.lineID)
                }
                .flatMap { [$0.fromStationID, $0.toStationID] }
        )

        identifier = document.identifier
        publishedAt = document.publishedAt
        sourceURL = document.sourceURL
        verifiedLineIDs = document.verifiedLineIDs
        belowGroundSegmentIDs = document.belowGroundSegmentIDs
        coveredTunnelSegmentIDs = document.coveredTunnelSegmentIDs
        belowGroundStationIDs = expandedBelowGroundStations
        coveredStationIDs = expandedCoveredStations
        stationOnlyCoverageStationIDs = expandedCoveredStations.subtracting(
            expandedCoveredTunnelStations
        )
        verifiedBelowGroundStationIDs = Self.expandedHubStationIDs(
            verifiedStationIDs,
            graph: graph
        )
    }

    func availability(
        for segment: TubeSegment,
        mode: MobileCoverageMode
    ) -> MobileCoverageAvailability {
        guard mode.isActive else { return .outOfScope }
        if coveredTunnelSegmentIDs.contains(segment.id) {
            return .available
        }
        guard belowGroundSegmentIDs.contains(segment.id) else {
            return mode == .allUsable ? .available : .outOfScope
        }
        return verifiedLineIDs.contains(segment.lineID) ? .unavailable : .unknown
    }

    func availability(
        for stationID: String,
        mode: MobileCoverageMode
    ) -> MobileCoverageAvailability {
        guard mode.isActive else { return .outOfScope }
        if coveredStationIDs.contains(stationID) {
            return .available
        }
        guard belowGroundStationIDs.contains(stationID) else {
            return mode == .allUsable ? .available : .outOfScope
        }
        return verifiedBelowGroundStationIDs.contains(stationID) ? .unavailable : .unknown
    }

    private static func expandedHubStationIDs(
        _ stationIDs: Set<String>,
        graph: TubeGraph
    ) -> Set<String> {
        Set(stationIDs.flatMap { stationID -> [String] in
            guard let station = graph.stationsByID[stationID] else { return [] }
            return graph.stations(inSamePlaceAs: station).map(\.id)
        })
    }
}

struct MobileCoverageRepository {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func load(graph: TubeGraph) throws -> MobileCoverageSnapshot {
        let url = try resourceURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MobileCoverageRepositoryError.unreadableResource(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        return try decode(data, graph: graph)
    }

    func decode(_ data: Data, graph: TubeGraph) throws -> MobileCoverageSnapshot {
        let document: MobileCoverageDocument
        do {
            document = try JSONDecoder().decode(MobileCoverageDocument.self, from: data)
        } catch {
            throw MobileCoverageRepositoryError.decodingFailed(error.localizedDescription)
        }
        return try MobileCoverageSnapshot(document: document, graph: graph)
    }

    private func resourceURL() throws -> URL {
        let name = "mobile-coverage-august-2026"
        let candidates = [
            "MobileCoverage/v1",
            "Resources/MobileCoverage/v1",
            nil,
        ]
        for subdirectory in candidates {
            if let url = bundle.url(
                forResource: name,
                withExtension: "json",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        throw MobileCoverageRepositoryError.missingResource(name)
    }
}

enum MobileCoverageRepositoryError: LocalizedError, Equatable {
    case missingResource(String)
    case unreadableResource(path: String, reason: String)
    case decodingFailed(String)
    case unsupportedSchema(Int)
    case graphMismatch(expected: String, actual: String)
    case unknownSegmentIDs([String])
    case unknownStationIDs([String])
    case coveredTunnelIsNotBelowGround

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            "Mobile coverage resource \(name).json is missing."
        case let .unreadableResource(path, reason):
            "Mobile coverage resource at \(path) could not be read: \(reason)"
        case let .decodingFailed(reason):
            "Mobile coverage data could not be decoded: \(reason)"
        case let .unsupportedSchema(version):
            "Mobile coverage schema version \(version) is unsupported."
        case let .graphMismatch(expected, actual):
            "Mobile coverage graph \(actual) does not match \(expected)."
        case let .unknownSegmentIDs(ids):
            "Mobile coverage references unknown segments: \(ids.joined(separator: ", "))."
        case let .unknownStationIDs(ids):
            "Mobile coverage references unknown stations: \(ids.joined(separator: ", "))."
        case .coveredTunnelIsNotBelowGround:
            "Mobile coverage marks a tunnel as covered without classifying it below ground."
        }
    }
}
