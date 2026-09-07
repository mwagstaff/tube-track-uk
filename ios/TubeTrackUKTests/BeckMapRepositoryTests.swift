import Foundation
import Testing
@testable import TubeTrackUK

struct BeckMapRepositoryTests {
    private let repository = BeckMapRepository()

    @Test func publishedRegionsAreLimitedToTraceVerifiedArtwork() {
        #expect(Set(BeckMapRegion.allCases.map(\.rawValue)) == [
            "full-underground",
            "eastern-fan",
            "central-completion",
            "central-core-join",
            "east-connector",
            "north-connector",
            "northwest-connector",
            "western-fan",
            "south-connector",
            "central-backbone",
            "west-connector",
            "heathrow",
        ])
    }

    @Test func bundledFullLondonRailMapIsCompleteAndStrictlyValidated() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        #expect(document.identifier == "tube-track-uk.beck.full-underground.v1")
        #expect(document.artworkSize == BeckMapSize(width: 4_764, height: 3_632))
        #expect(document.segments.count == graph.segments.count + 1)
        #expect(document.stationMarkers.count == graph.stations.count)
        #expect(document.labels.count >= 330)
        #expect(document.lineCoverage == Set(TubeLineID.allCases))
        let river = try #require(document.waterways?.first { $0.id == "river-thames" })
        let riverPath = try #require(document.paths.first { $0.id == river.pathID })
        #expect(river.name == "River Thames")
        #expect(river.strokeWidth > document.styles.routeStrokeWidth)
        #expect(riverPath.commands.count >= 20)
        #expect(riverPath.commands.allSatisfy {
            if case .move = $0 { return true }
            if case .line = $0 { return true }
            return false
        })
        #expect(Set(graph.segments.map(\.id)).isSubset(of: Set(document.segments.map(\.id))))
        #expect(Set(document.segments.map(\.pathID)).isSubset(of: Set(document.paths.map(\.id))))
        #expect(document.segments.filter { $0.lineID == .dlr }.count == 46)
        #expect(document.segments.filter { $0.lineID == .elizabeth }.count == 42)
        #expect(document.segments.filter {
            [.liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush].contains($0.lineID)
        }.count == 112)
        #expect(document.segments.contains {
            $0.id == BeckMapRepository.supplementalHeathrowSegmentID
        })
    }

    @Test func fullMapConnectorEndpointsRemainCoveredByRoundels() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let roundelCentres = document.stationMarkers.flatMap { marker in
            marker.primitives.compactMap { primitive -> BeckMapPoint? in
                guard case let .circle(circle) = primitive else { return nil }
                return circle.centre
            }
        }
        let connectorEndpoints = document.stationMarkers.flatMap { marker in
            marker.primitives.flatMap { primitive -> [BeckMapPoint] in
                guard case let .connector(connector) = primitive else { return [] }
                return [connector.start, connector.end]
            }
        }

        #expect(!connectorEndpoints.isEmpty)
        #expect(connectorEndpoints.allSatisfy { endpoint in
            roundelCentres.contains { centre in
                hypot(endpoint.x - centre.x, endpoint.y - centre.y) <= 8.5
            }
        })
    }

    @Test func splitInterchangeRoundelsRetainTheirPassengerFacingLines() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        let barkingSuffragette = try #require(document.stationMarkers.first {
            $0.stationID == "910GBARKING"
        })
        let westHam = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWHM"
        })
        let westBromptonMildmay = try #require(document.stationMarkers.first {
            $0.stationID == "910GWBRMPTN"
        })

        #expect(barkingSuffragette.lineIDs == [.suffragette])
        #expect(westHam.lineIDs.contains(.jubilee))
        #expect(westBromptonMildmay.lineIDs == [.mildmay])
    }

    @Test func isolatedSingleLineStationsUseTicksAcrossEveryNetwork() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let stationsByID = graph.stationsByID
        let hubSizes = Dictionary(
            grouping: graph.stations,
            by: { $0.hubID ?? $0.id }
        ).mapValues(\.count)
        let connectorEndpoints = document.stationMarkers.flatMap { marker in
            marker.primitives.flatMap { primitive -> [BeckMapPoint] in
                switch primitive {
                case let .connector(connector), let .walkingConnector(connector):
                    [connector.start, connector.end]
                case .circle, .tick:
                    []
                }
            }
        }
        let additionalConnectedStationIDs: Set<String> = [
            "910GHACKNYC", "910GHAKNYNM", "910GHAYESAH",
        ]
        let ordinaryMarkers = try document.stationMarkers.filter { marker in
            let station = try #require(stationsByID[marker.stationID])
            let hubID = station.hubID ?? station.id
            let touchesConnection = connectorEndpoints.contains { endpoint in
                hypot(endpoint.x - marker.anchor.x, endpoint.y - marker.anchor.y) <= 10
            }
            return station.lineIDs.count == 1
                && hubSizes[hubID] == 1
                && !additionalConnectedStationIDs.contains(marker.stationID)
                && !touchesConnection
        }

        #expect(ordinaryMarkers.count > 150)
        #expect(ordinaryMarkers.allSatisfy { marker in
            marker.primitives.contains { if case .tick = $0 { true } else { false } }
                && !marker.primitives.contains { if case .circle = $0 { true } else { false } }
        })
    }

    @Test func fullUndergroundMapContainsExactVectorSeams() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        let seamSegments = try [
            "circle:940GZZLUBST:940GZZLUGPS",
            "hammersmith-city:940GZZLUFCN:940GZZLUKSX",
            "metropolitan:940GZZLULVT:940GZZLUMGT",
            "waterloo-city:940GZZLUBNK:940GZZLUWLO",
            "piccadilly:940GZZLUHNX:940GZZLUHWT",
        ].map { segmentID in
            try #require(document.segments.first { $0.id == segmentID })
        }
        #expect(seamSegments.allSatisfy { $0.pathID.contains(".full.v1.") })
        let seamPathIDs = Set(seamSegments.map(\.pathID))
        #expect(document.paths.filter { seamPathIDs.contains($0.id) }.contains {
            $0.commands.contains { if case .cubic = $0 { return true }; return false }
        })
    }

    @Test func fullUndergroundMapCoversEveryDLRAndElizabethSemanticSegment() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let railLineIDs: Set<TubeLineID> = [.dlr, .elizabeth]
        let graphSegmentIDs = Set(graph.segments.filter {
            railLineIDs.contains($0.lineID)
        }.map(\.id))
        let authoredSegments = document.segments.filter {
            railLineIDs.contains($0.lineID)
        }
        let authoredSegmentIDs = Set(authoredSegments.map(\.id))
        let pathIDs = Set(document.paths.map(\.id))

        #expect(authoredSegmentIDs == graphSegmentIDs)
        #expect(authoredSegments.allSatisfy {
            $0.fromPort != nil && $0.toPort != nil && pathIDs.contains($0.pathID)
        })
        #expect(document.routes.filter {
            railLineIDs.contains($0.lineID)
        }.allSatisfy { route in
            Set(route.segmentIDs).isSubset(of: authoredSegmentIDs)
                && route.stationIDs.count == route.segmentIDs.count + 1
        })
    }

    @Test func dlrAndElizabethPathsRetainTheOfficialCubicContours() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })

        for lineID in [TubeLineID.dlr, .elizabeth] {
            let referencedPathIDs = Set(document.segments.filter {
                $0.lineID == lineID
            }.map(\.pathID))
            let cubicCommandCount = referencedPathIDs.reduce(into: 0) { count, pathID in
                count += pathsByID[pathID]?.commands.count {
                    if case .cubic = $0 { return true }
                    return false
                } ?? 0
            }

            // The TfL masters contain rounded joins and branch contours. A
            // straight station-to-station interpolation has no cubic commands.
            #expect(cubicCommandCount >= 10)
        }
    }

    @Test func fullMapCoversEveryNamedOvergroundSemanticSegment() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let lineIDs: Set<TubeLineID> = [
            .liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush,
        ]
        let graphSegmentIDs = Set(graph.segments.filter {
            lineIDs.contains($0.lineID)
        }.map(\.id))
        let authoredSegments = document.segments.filter {
            lineIDs.contains($0.lineID)
        }
        let authoredSegmentIDs = Set(authoredSegments.map(\.id))
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })

        #expect(authoredSegmentIDs == graphSegmentIDs)
        #expect(authoredSegments.allSatisfy {
            $0.fromPort != nil
                && $0.toPort != nil
                && pathsByID[$0.pathID] != nil
                && $0.pathID.contains(".official.v1.")
        })
        for lineID in lineIDs.subtracting([.liberty]) {
            let pathIDs = Set(authoredSegments.filter { $0.lineID == lineID }.map(\.pathID))
            #expect(pathIDs.contains { pathID in
                pathsByID[pathID]?.commands.contains {
                    if case .cubic = $0 { return true }
                    return false
                } == true
            })
        }
    }

    @Test func overgroundInterchangesUseCompactOfficialMarkerLayouts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func marker(_ stationID: String) throws -> BeckMapStationMarkerRecord {
            try #require(document.stationMarkers.first { $0.stationID == stationID })
        }

        func circles(_ marker: BeckMapStationMarkerRecord) -> [BeckMapPoint] {
            marker.primitives.compactMap {
                if case let .circle(circle) = $0 { return circle.centre }
                return nil
            }
        }

        func connectors(_ marker: BeckMapStationMarkerRecord) -> [BeckMapLinePrimitive] {
            marker.primitives.compactMap {
                switch $0 {
                case let .connector(connector), let .walkingConnector(connector):
                    return connector
                case .circle, .tick:
                    return nil
                }
            }
        }

        func tickCount(_ marker: BeckMapStationMarkerRecord) -> Int {
            marker.primitives.count { if case .tick = $0 { return true }; return false }
        }

        func port(_ stationID: String, _ lineID: TubeLineID) throws -> BeckMapPoint {
            try #require(document.segments.compactMap { segment -> BeckMapPoint? in
                guard segment.lineID == lineID else { return nil }
                if segment.fromStationID == stationID { return segment.fromPort }
                if segment.toStationID == stationID { return segment.toPort }
                return nil
            }.first)
        }

        func length(_ connector: BeckMapLinePrimitive) -> Double {
            hypot(
                connector.end.x - connector.start.x,
                connector.end.y - connector.start.y
            )
        }

        // Shared rail records normally resolve to one physical roundel. TfL
        // gives Hackney Downs two Weaver branch ports plus Hackney Central's
        // connected roundel.
        #expect(circles(try marker("910GROMFORD")).count == 1)
        let hackneyDowns = try marker("910GHAKNYNM")
        #expect(circles(hackneyDowns).count == 3)
        #expect(connectors(hackneyDowns).count == 2)

        // These Underground interchanges use roundels, not ordinary ticks.
        for stationID in [
            "940GZZLUSVS", "940GZZLUBLR", "940GZZLUWWL",
            "940GZZLUHAI", "940GZZLUCAR", "940GZZLUWHP",
        ] {
            let stationMarker = try marker(stationID)
            #expect(circles(stationMarker).count == 1)
            #expect(tickCount(stationMarker) == 0)
        }

        let compactInterchanges: [(String, Double)] = [
            ("910GSEVNSIS", 40),
            ("910GBLCHSRD", 30),
            ("910GWLTWCEN", 25),
            ("910GHGHI", 32),
            ("910GCLDNNRB", 55),
            ("910GWHMDSTD", 55),
            ("910GFNCHLYR", 90),
            ("910GBARKING", 60),
        ]
        for (stationID, maximumLength) in compactInterchanges {
            let links = connectors(try marker(stationID))
            #expect(!links.isEmpty)
            #expect(links.allSatisfy { length($0) <= maximumLength })
        }
        for stationID in ["910GWHMDSTD", "910GFNCHLYR"] {
            #expect(try marker(stationID).primitives.contains {
                if case .walkingConnector = $0 { return true }
                return false
            })
        }
        let caledonianLink = try #require(
            connectors(try marker("910GCLDNNRB")).first
        )
        #expect(abs(
            abs(caledonianLink.end.x - caledonianLink.start.x)
                - abs(caledonianLink.end.y - caledonianLink.start.y)
        ) < 0.01)
        let blackhorseLink = try #require(
            connectors(try marker("910GBLCHSRD")).first
        )
        #expect(blackhorseLink.end.x > blackhorseLink.start.x)
        #expect(blackhorseLink.end.y < blackhorseLink.start.y)
        #expect(abs(
            abs(blackhorseLink.end.x - blackhorseLink.start.x)
                - abs(blackhorseLink.end.y - blackhorseLink.start.y)
        ) < 0.01)

        // Queen's Park keeps the official small separation between the
        // Bakerloo and Lioness traces while retaining one shared roundel.
        let queensBakerloo = try port("940GZZLUQPS", .bakerloo)
        let queensLioness = try port("910GQPRK", .lioness)
        #expect(abs(hypot(
            queensBakerloo.x - queensLioness.x,
            queensBakerloo.y - queensLioness.y
        ) - 13.078) < 0.001)
        #expect(circles(try marker("940GZZLUQPS")).count == 1)
        #expect(circles(try marker("910GQPRK")).count == 1)
        #expect(circles(try marker("940GZZLUQPS")) == circles(try marker("910GQPRK")))
        for segmentID in [
            "lioness:910GKLBRNHR:910GQPRK",
            "lioness:910GKENSLG:910GQPRK",
        ] {
            let segment = try #require(document.segments.first { $0.id == segmentID })
            let path = try #require(document.paths.first { $0.id == segment.pathID })
            #expect(path.commands.count >= 4)
            #expect(path.commands.count {
                if case .cubic = $0 { return true }
                return false
            } >= 1)
        }

        let kensalToWillesden = try #require(document.segments.first {
            $0.id == "lioness:910GKENSLG:910GWLSDJHL"
        })
        let kensalToWillesdenPath = try #require(document.paths.first {
            $0.id == kensalToWillesden.pathID
        })
        let kensalPort = try #require(kensalToWillesden.fromPort)
        let willesdenPort = try #require(kensalToWillesden.toPort)
        #expect(kensalToWillesdenPath.commands == [
            .move(to: kensalPort),
            .line(to: willesdenPort),
        ])
        #expect(abs(kensalPort.x - willesdenPort.x) < 0.001)

        // The parallel Bakerloo/Lioness corridor uses short horizontal links.
        for (overgroundID, undergroundID) in [
            ("910GKENSLG", "940GZZLUKSL"),
            ("910GHARLSDN", "940GZZLUHSN"),
            ("910GSTNBGPK", "940GZZLUSGP"),
            ("910GWMBY", "940GZZLUWYC"),
            ("910GNWEMBLY", "940GZZLUNWY"),
            ("910GSKENTON", "940GZZLUSKT"),
            ("910GKTON", "940GZZLUKEN"),
            ("910GHROW", "940GZZLUHAW"),
        ] {
            let lioness = try port(overgroundID, .lioness)
            let bakerloo = try port(undergroundID, .bakerloo)
            #expect(abs(lioness.y - bakerloo.y) < 0.1)
            #expect(abs(lioness.x - bakerloo.x) < 15)
        }

        // Stratford's four displayed nodes are distinct, with no duplicated
        // Jubilee/Elizabeth ring at the shared centre.
        let stratfordCentres = try ["940GZZLUSTD", "910GSTFD", "940GZZDLSTD"]
            .flatMap { circles(try marker($0)) }
        #expect(stratfordCentres.count == 4)
        for (index, centre) in stratfordCentres.enumerated() {
            for other in stratfordCentres.dropFirst(index + 1) {
                #expect(hypot(centre.x - other.x, centre.y - other.y) > 10)
            }
        }
    }

    @Test func fullMapCoversEveryLondonTramsSemanticSegment() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let graphSegmentIDs = Set(graph.segments.filter {
            $0.lineID == .tram
        }.map(\.id))
        let authoredSegments = document.segments.filter { $0.lineID == .tram }
        let authoredSegmentIDs = Set(authoredSegments.map(\.id))
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })
        let routes = document.routes.filter { $0.lineID == .tram }

        #expect(graphSegmentIDs.count == 40)
        #expect(authoredSegmentIDs == graphSegmentIDs)
        #expect(authoredSegments.allSatisfy {
            $0.fromPort != nil
                && $0.toPort != nil
                && pathsByID[$0.pathID] != nil
                && $0.pathID.contains(".official.v1.")
        })
        #expect(routes.count == 6)
        #expect(routes.allSatisfy { route in
            route.stationIDs.count == route.segmentIDs.count + 1
                && Set(route.segmentIDs).isSubset(of: authoredSegmentIDs)
        })

        let cubicCount = authoredSegments.reduce(into: 0) { count, segment in
            count += pathsByID[segment.pathID]?.commands.count {
                if case .cubic = $0 { return true }
                return false
            } ?? 0
        }
        #expect(cubicCount >= 18)

        // The loop, its western link and the Centrale-Church Street chord are
        // all separate semantic edges; none may be replaced by a direct chord.
        let croydonTopology: Set<String> = [
            "tram:940GZZCRRVC:940GZZCRWAN",
            "tram:940GZZCRCTR:940GZZCRRVC",
            "tram:940GZZCRCTR:940GZZCRWCR",
            "tram:940GZZCRWCR:940GZZCRWEL",
            "tram:940GZZCRECR:940GZZCRWEL",
            "tram:940GZZCRCEN:940GZZCRECR",
            "tram:940GZZCRCEN:940GZZCRCHR",
            "tram:940GZZCRCHR:940GZZCRWAN",
            "tram:940GZZCRCHR:940GZZCRCTR",
        ]
        #expect(croydonTopology.isSubset(of: authoredSegmentIDs))
    }

    @Test func londonTramsUsesOfficialPortsAndDistinctConnectedInterchanges() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func marker(_ stationID: String) throws -> BeckMapStationMarkerRecord {
            try #require(document.stationMarkers.first { $0.stationID == stationID })
        }

        func circles(_ marker: BeckMapStationMarkerRecord) -> [BeckMapPoint] {
            marker.primitives.compactMap {
                if case let .circle(circle) = $0 { return circle.centre }
                return nil
            }
        }

        func connectors(_ marker: BeckMapStationMarkerRecord) -> [BeckMapLinePrimitive] {
            marker.primitives.compactMap {
                if case let .connector(connector) = $0 { return connector }
                return nil
            }
        }

        func ports(_ stationID: String) -> [BeckMapPoint] {
            document.segments.compactMap { segment in
                guard segment.lineID == .tram else { return nil }
                if segment.fromStationID == stationID { return segment.fromPort }
                if segment.toStationID == stationID { return segment.toPort }
                return nil
            }
        }

        func isNear(_ point: BeckMapPoint, _ expected: BeckMapPoint) -> Bool {
            hypot(point.x - expected.x, point.y - expected.y) < 2
        }

        let officialTermini: [(String, BeckMapPoint)] = [
            ("940GZZCRWMB", BeckMapPoint(x: 1_387.281, y: 2_406.609)),
            ("940GZZCRBEK", BeckMapPoint(x: 3_804.578, y: 2_514.875)),
            ("940GZZCRELM", BeckMapPoint(x: 3_434.876, y: 2_575.515)),
            ("940GZZCRNWA", BeckMapPoint(x: 3_416.859, y: 2_982.078)),
        ]
        for (stationID, expected) in officialTermini {
            #expect(ports(stationID).contains { isNear($0, expected) })
        }

        // Branch semantics terminate at the exact green joins beside the stop
        // symbols, preserving TfL's loops instead of inventing straight links.
        let officialJoinPorts: [(String, String, BeckMapPoint)] = [
            (
                "tram:940GZZCRADD:940GZZCRSAN", "940GZZCRSAN",
                BeckMapPoint(x: 3_179.219, y: 2_756.719)
            ),
            (
                "tram:940GZZCRARA:940GZZCRELM", "940GZZCRARA",
                BeckMapPoint(x: 3_364.094, y: 2_584.359)
            ),
            (
                "tram:940GZZCRCTR:940GZZCRRVC", "940GZZCRCTR",
                BeckMapPoint(x: 2_572.422, y: 2_682.281)
            ),
            (
                "tram:940GZZCRCHR:940GZZCRCTR", "940GZZCRCHR",
                BeckMapPoint(x: 2_603.188, y: 2_756.672)
            ),
        ]
        for (segmentID, stationID, expected) in officialJoinPorts {
            let segment = try #require(document.segments.first { $0.id == segmentID })
            let port = segment.fromStationID == stationID
                ? segment.fromPort
                : segment.toPort
            #expect(port.map { isNear($0, expected) } == true)
        }

        for (firstID, secondID) in [
            ("940GZZLUWIM", "940GZZCRWMB"),
            ("910GWCROYDN", "940GZZCRWCR"),
        ] {
            let first = try marker(firstID)
            let second = try marker(secondID)
            let firstCircle = try #require(circles(first).first { $0 == first.anchor })
            let secondCircle = try #require(circles(second).first { $0 == second.anchor })
            #expect(circles(first).count == 1)
            #expect(hypot(
                firstCircle.x - secondCircle.x,
                firstCircle.y - secondCircle.y
            ) > 40)
            let connector = try #require(connectors(second).first)
            #expect(connector.start == firstCircle)
            #expect(connector.end == secondCircle)

            if secondID == "940GZZCRWCR" {
                // West Croydon's Overground marker is drawn first, so the Tram
                // marker redraws that endpoint above its connector.
                #expect(circles(second).contains(firstCircle))
                #expect(circles(second).count == 2)
            } else {
                #expect(circles(second).count == 1)
            }
        }
    }

    @Test func correctedNorthLondonPathsStayMonotoneAndKinkFree() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func segmentAndPath(_ segmentID: String) throws -> (
            BeckMapSegmentRecord, BeckMapPathRecord
        ) {
            let segment = try #require(document.segments.first { $0.id == segmentID })
            let path = try #require(document.paths.first { $0.id == segment.pathID })
            return (segment, path)
        }

        func commandPoints(_ path: BeckMapPathRecord) -> [BeckMapPoint] {
            path.commands.flatMap { command in
                switch command {
                case let .move(to), let .line(to):
                    return [to]
                case let .cubic(control1, control2, to):
                    return [control1, control2, to]
                case .close:
                    return []
                }
            }
        }

        // The two Weaver joins previously retained overlapping source
        // fragments, briefly travelling east/south before doubling back.
        for segmentID in [
            "weaver:910GCAMHTH:910GLONFLDS",
            "weaver:910GCLAPTON:910GHAKNYNM",
        ] {
            let (segment, path) = try segmentAndPath(segmentID)
            let from = try #require(segment.fromPort)
            let to = try #require(segment.toPort)
            let xRange = min(from.x, to.x)...max(from.x, to.x)
            let yRange = min(from.y, to.y)...max(from.y, to.y)
            #expect(commandPoints(path).allSatisfy { point in
                xRange.contains(point.x) && yRange.contains(point.y)
            })
            #expect(path.commands.count {
                if case .cubic = $0 { return true }
                return false
            } == 1)
        }

        // Every rebuilt northeast Victoria slice is a single horizontal line,
        // ordered Seven Sisters → Tottenham Hale → Blackhorse → Walthamstow.
        for segmentID in [
            "victoria:940GZZLUSVS:940GZZLUTMH",
            "victoria:940GZZLUBLR:940GZZLUTMH",
            "victoria:940GZZLUBLR:940GZZLUWWL",
        ] {
            let (segment, path) = try segmentAndPath(segmentID)
            let from = try #require(segment.fromPort)
            let to = try #require(segment.toPort)
            #expect(path.commands == [.move(to: from), .line(to: to)])
            #expect(abs(from.y - to.y) < 0.001)
            #expect(from.x < to.x)
        }

        let (_, highburyToFinsbury) = try segmentAndPath(
            "victoria:940GZZLUFPK:940GZZLUHAI"
        )
        let highburyXs = commandPoints(highburyToFinsbury).map(\.x)
        #expect((highburyXs.max() ?? 0) - (highburyXs.min() ?? 0) < 0.05)

        let (caledonianToHolloway, caledonianPath) = try segmentAndPath(
            "piccadilly:940GZZLUCAR:940GZZLUHWY"
        )
        let caledonian = try #require(caledonianToHolloway.fromPort)
        let holloway = try #require(caledonianToHolloway.toPort)
        #expect(caledonianPath.commands == [
            .move(to: caledonian),
            .line(to: holloway),
        ])
        #expect(caledonian.x < holloway.x)
        #expect(caledonian.y > holloway.y)
        #expect(abs(caledonian.x + caledonian.y - 3_437.578) < 0.01)

        let mildmayCaledonian = try #require(document.stationMarkers.first {
            $0.stationID == "910GCLDNNRB"
        })
        for stationID in ["940GZZLUCAR", "940GZZLUHWY", "940GZZLUASL"] {
            let marker = try #require(document.stationMarkers.first {
                $0.stationID == stationID
            })
            #expect(marker.anchor.y < mildmayCaledonian.anchor.y)
        }
    }

    @Test func railExtensionTerminiStayOnTheirOfficialTfLPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func stationPorts(_ stationID: String, on lineID: TubeLineID) -> [BeckMapPoint] {
            document.segments.compactMap { segment in
                guard segment.lineID == lineID else { return nil }
                if segment.fromStationID == stationID { return segment.fromPort }
                if segment.toStationID == stationID { return segment.toPort }
                return nil
            }
        }

        let officialTermini: [(TubeLineID, String, BeckMapPoint)] = [
            (.dlr, "940GZZDLBEC", BeckMapPoint(x: 3_627.9, y: 2_165.0)),
            (.dlr, "940GZZDLLEW", BeckMapPoint(x: 3_027.3, y: 2_456.9)),
            (.elizabeth, "910GRDNGSTN", BeckMapPoint(x: 160.3, y: 960.4)),
            (.elizabeth, "910GSHENFLD", BeckMapPoint(x: 4_009.3, y: 765.8)),
            (.elizabeth, "910GABWDXR", BeckMapPoint(x: 3_563.9, y: 2_319.3)),
        ]

        for (lineID, stationID, expected) in officialTermini {
            let ports = stationPorts(stationID, on: lineID)
            #expect(!ports.isEmpty)
            #expect(ports.contains { port in
                hypot(port.x - expected.x, port.y - expected.y) < 8
            })
        }
    }

    @Test func dlrBankSharesTheNorthernRoundelButNotTheCentralAnchor() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let dlrBank = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZDLBNK"
        })
        let undergroundBank = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUBNK"
        })

        let undergroundRoundels = undergroundBank.primitives.compactMap {
            if case let .circle(circle) = $0 { return circle.centre }
            return nil
        }

        // DLR shares Bank's southeastern Northern roundel, while the Bank
        // marker anchor remains on the separate Central/Waterloo & City node.
        #expect(undergroundRoundels.contains(dlrBank.anchor))
        #expect(hypot(
            dlrBank.anchor.x - undergroundBank.anchor.x,
            dlrBank.anchor.y - undergroundBank.anchor.y
        ) > 40)
    }

    @Test func fullUndergroundMapUsesExplicitSpecialStationMarkerTemplates() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func marker(_ stationID: String) throws -> BeckMapStationMarkerRecord {
            try #require(document.stationMarkers.first { $0.stationID == stationID })
        }

        func circleCount(_ marker: BeckMapStationMarkerRecord) -> Int {
            marker.primitives.count { if case .circle = $0 { return true }; return false }
        }

        func connectorCount(_ marker: BeckMapStationMarkerRecord) -> Int {
            marker.primitives.count { if case .connector = $0 { return true }; return false }
        }

        func connectors(_ marker: BeckMapStationMarkerRecord) -> [BeckMapLinePrimitive] {
            marker.primitives.compactMap {
                if case let .connector(connector) = $0 { return connector }
                return nil
            }
        }

        func tickCount(_ marker: BeckMapStationMarkerRecord) -> Int {
            marker.primitives.count { if case .tick = $0 { return true }; return false }
        }

        func circleCentres(_ marker: BeckMapStationMarkerRecord) -> [BeckMapPoint] {
            marker.primitives.compactMap {
                if case let .circle(circle) = $0 { return circle.centre }
                return nil
            }
        }

        func stationLinePort(_ stationID: String, _ lineID: TubeLineID) -> BeckMapPoint {
            let ports = document.segments.compactMap { segment -> BeckMapPoint? in
                guard segment.lineID == lineID else { return nil }
                if segment.fromStationID == stationID { return segment.fromPort }
                if segment.toStationID == stationID { return segment.toPort }
                return nil
            }
            let uniquePorts = ports.reduce(into: [BeckMapPoint]()) { result, port in
                if !result.contains(port) { result.append(port) }
            }
            #expect(!uniquePorts.isEmpty)
            let count = Double(max(uniquePorts.count, 1))
            return BeckMapPoint(
                x: uniquePorts.reduce(0) { $0 + $1.x } / count,
                y: uniquePorts.reduce(0) { $0 + $1.y } / count
            )
        }

        func commandDestinations(_ pathID: String) throws -> [BeckMapPoint] {
            let path = try #require(document.paths.first { $0.id == pathID })
            return path.commands.compactMap { command in
                switch command {
                case let .move(to): to
                case let .line(to): to
                case let .cubic(_, _, to): to
                case .close: nil
                }
            }
        }

        let turnhamGreen = try marker("940GZZLUTNG")
        #expect(circleCount(turnhamGreen) == 2)
        #expect(connectorCount(turnhamGreen) == 1)

        let finchleyCentral = try marker("940GZZLUFYC")
        #expect(circleCount(finchleyCentral) == 0)
        #expect(tickCount(finchleyCentral) == 1)
        #expect(connectorCount(finchleyCentral) == 0)
        let millHillEast = try marker("940GZZLUMHL")
        #expect(finchleyCentral.anchor.y > millHillEast.anchor.y)
        let finchleyPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .northern else { return nil }
            if segment.fromStationID == finchleyCentral.stationID {
                return segment.fromPort
            }
            if segment.toStationID == finchleyCentral.stationID {
                return segment.toPort
            }
            return nil
        }
        #expect(finchleyPorts.count == 3)
        #expect(finchleyPorts.allSatisfy { $0 == finchleyCentral.anchor })

        let camdenTown = try marker("940GZZLUCTN")
        #expect(circleCount(camdenTown) == 0)
        #expect(tickCount(camdenTown) == 1)
        #expect(connectorCount(camdenTown) == 0)

        let edgwareRoad = try marker("940GZZLUERC")
        #expect(circleCount(edgwareRoad) == 2)
        #expect(connectorCount(edgwareRoad) == 1)

        let bakerStreet = try marker("940GZZLUBST")
        #expect(circleCount(bakerStreet) == 2)
        #expect(connectorCount(bakerStreet) == 1)
        let bakerConnector = try #require(connectors(bakerStreet).first)
        let bakerJubileePort = stationLinePort("940GZZLUBST", .jubilee)
        #expect(abs(bakerConnector.start.x - bakerJubileePort.x) < 0.05)
        #expect(bakerConnector.end.x - bakerJubileePort.x > 20)

        let aldgate = try marker("940GZZLUALD")
        #expect(circleCount(aldgate) == 0)
        #expect(connectorCount(aldgate) == 0)
        #expect(tickCount(aldgate) == 2)
        let aldgateCirclePort = stationLinePort("940GZZLUALD", .circle)
        let aldgateMetropolitanPort = stationLinePort("940GZZLUALD", .metropolitan)
        #expect(abs(aldgateCirclePort.y - aldgateMetropolitanPort.y) < 0.01)
        #expect(abs(aldgateCirclePort.x - aldgateMetropolitanPort.x) < 10)
        let aldgateMetropolitanSegment = try #require(document.segments.first {
            $0.id == "metropolitan:940GZZLUALD:940GZZLULVT"
        })
        let aldgateMetropolitanDestinations = try commandDestinations(
            aldgateMetropolitanSegment.pathID
        )
        #expect(aldgateMetropolitanDestinations.last == aldgateMetropolitanPort)

        let bondStreet = try marker("940GZZLUBND")
        #expect(circleCount(bondStreet) == 3)
        #expect(connectorCount(bondStreet) == 2)
        let bondCentralPort = stationLinePort("940GZZLUBND", .central)
        let bondJubileePort = stationLinePort("940GZZLUBND", .jubilee)
        let bondCentres = circleCentres(bondStreet)
        #expect(bondCentres.contains(bondCentralPort))
        #expect(bondCentres.contains(bondJubileePort))
        #expect(abs(bondCentralPort.x - bondJubileePort.x) < 50)
        #expect(bondJubileePort.y - bondCentralPort.y > 20)

        let marbleArch = try marker("940GZZLUMBA")
        #expect(circleCount(marbleArch) == 0)
        #expect(connectorCount(marbleArch) == 0)
        #expect(tickCount(marbleArch) == 1)
        let marbleArchPort = stationLinePort("940GZZLUMBA", .central)
        #expect(bondJubileePort.x - marbleArchPort.x > 15)

        let bakerMetropolitanSegment = try #require(document.segments.first {
            $0.id == "metropolitan:940GZZLUBST:940GZZLUGPS"
        })
        let bakerMetropolitanDestinations = try commandDestinations(
            bakerMetropolitanSegment.pathID
        )
        #expect(bakerMetropolitanDestinations.count == 2)
        #expect(
            bakerMetropolitanDestinations[1].x
                > bakerMetropolitanDestinations[0].x
        )
        #expect(
            abs(
                bakerMetropolitanDestinations[1].y
                    - bakerMetropolitanDestinations[0].y
            ) < 0.001
        )

        let bakerMetropolitanInboundSegment = try #require(
            document.segments.first {
                $0.id == "metropolitan:940GZZLUBST:940GZZLUFYR"
            }
        )
        let bakerMetropolitanInboundDestinations = try commandDestinations(
            bakerMetropolitanInboundSegment.pathID
        )
        let bakerMetropolitanInboundLead = try #require(
            bakerMetropolitanInboundDestinations.dropLast().last
        )
        let bakerMetropolitanInboundPort = try #require(
            bakerMetropolitanInboundDestinations.last
        )
        #expect(
            abs(
                bakerMetropolitanInboundLead.y
                    - bakerMetropolitanInboundPort.y
            ) < 0.001
        )
        #expect(
            bakerMetropolitanInboundPort.x
                - bakerMetropolitanInboundLead.x > 20
        )
        #expect(
            abs(
                bakerMetropolitanInboundPort.y
                    - bakerMetropolitanDestinations[0].y
            ) < 0.001
        )

        let greatPortlandEustonSquareSegment = try #require(
            document.segments.first {
                $0.id == "metropolitan:940GZZLUESQ:940GZZLUGPS"
            }
        )
        let greatPortlandEustonSquareDestinations = try commandDestinations(
            greatPortlandEustonSquareSegment.pathID
        )
        #expect(greatPortlandEustonSquareDestinations.count == 2)
        #expect(
            greatPortlandEustonSquareDestinations[1].x
                > greatPortlandEustonSquareDestinations[0].x
        )
        #expect(
            abs(
                greatPortlandEustonSquareDestinations[1].y
                    - greatPortlandEustonSquareDestinations[0].y
            ) < 0.001
        )
        #expect(
            abs(
                greatPortlandEustonSquareDestinations[0].y
                    - bakerMetropolitanDestinations[0].y
            ) < 0.001
        )

        let greatPortlandStreet = try marker("940GZZLUGPS")
        #expect(circleCount(greatPortlandStreet) == 0)
        #expect(connectorCount(greatPortlandStreet) == 0)
        #expect(tickCount(greatPortlandStreet) == 3)

        let eustonSquare = try marker("940GZZLUESQ")
        #expect(circleCount(eustonSquare) == 1)
        #expect(connectorCount(eustonSquare) == 0)

        let euston = try marker("940GZZLUEUS")
        #expect(eustonSquare.anchor.x < euston.anchor.x - 60)

        let kingsCross = try marker("940GZZLUKSX")
        #expect(circleCount(kingsCross) == 2)
        #expect(connectorCount(kingsCross) == 1)

        let paddingtonMain = try marker("940GZZLUPAC")
        let paddingtonHammersmith = try marker("940GZZLUPAH")
        #expect(circleCount(paddingtonMain) == 2)
        #expect(connectorCount(paddingtonMain) == 2)
        #expect(circleCount(paddingtonHammersmith) == 1)
        #expect(connectorCount(paddingtonHammersmith) == 0)

        let paddingtonCentres = circleCentres(paddingtonMain).sorted { $0.y < $1.y }
        #expect(paddingtonCentres.count == 2)
        #expect(paddingtonCentres[0].y < paddingtonHammersmith.anchor.y)
        #expect(paddingtonHammersmith.anchor.y < paddingtonCentres[1].y)
        #expect(paddingtonHammersmith.anchor.x < paddingtonCentres[1].x)
        let paddingtonConnectors = connectors(paddingtonMain)
        #expect(paddingtonConnectors[0].start == paddingtonCentres[0])
        #expect(paddingtonConnectors[0].end == paddingtonHammersmith.anchor)
        #expect(paddingtonConnectors[1].start == paddingtonHammersmith.anchor)
        #expect(paddingtonConnectors[1].end == paddingtonCentres[1])

        let royalOak = try marker("940GZZLURYO")
        #expect(circleCount(royalOak) == 0)
        #expect(tickCount(royalOak) == 2)
        #expect(connectorCount(royalOak) == 0)
        #expect(paddingtonHammersmith.anchor.x - royalOak.anchor.x > 30)

        let edgwareRoadCircle = try marker("940GZZLUERC")
        #expect(edgwareRoadCircle.anchor.x - paddingtonHammersmith.anchor.x > 60)
        let edgwareCentres = circleCentres(edgwareRoadCircle).sorted { $0.y < $1.y }
        let edgwareTerminatingSegments = document.segments.filter {
            $0.toStationID == "940GZZLUERC"
                && $0.fromStationID == "940GZZLUPAC"
                && ($0.lineID == .circle || $0.lineID == .district)
        }
        #expect(edgwareTerminatingSegments.count == 2)
        #expect(edgwareTerminatingSegments.allSatisfy {
            $0.toPort.map { abs($0.x - edgwareCentres[1].x) < 0.01 } == true
        })

        let woodford = try marker("940GZZLUWOF")
        #expect(circleCount(woodford) == 0)
        #expect(tickCount(woodford) == 1)
        #expect(connectorCount(woodford) == 0)

        let barking = try marker("940GZZLUBKG")
        #expect(circleCount(barking) == 1)
        #expect(connectorCount(barking) == 0)

        let westHam = try marker("940GZZLUWHM")
        #expect(circleCount(westHam) == 2)
        #expect(connectorCount(westHam) == 1)
        let westHamJubilee = stationLinePort("940GZZLUWHM", .jubilee)
        let westHamDistrict = stationLinePort("940GZZLUWHM", .district)
        #expect(westHam.anchor == westHamJubilee)
        #expect(westHamDistrict.x - westHamJubilee.x > 20)
        #expect(westHamDistrict.y - westHamJubilee.y > 20)

        let canningTownJubilee = stationLinePort("940GZZLUCGT", .jubilee)
        let stratfordJubilee = stationLinePort("940GZZLUSTD", .jubilee)
        #expect(abs(canningTownJubilee.x - westHamJubilee.x) < 0.05)
        #expect(abs(stratfordJubilee.x - westHamJubilee.x) < 0.05)
        #expect(canningTownJubilee.y > westHamJubilee.y)
        #expect(westHamJubilee.y > stratfordJubilee.y)

        let canaryWharf = try marker("940GZZLUCYF")
        let northGreenwichMarker = try marker("940GZZLUNGW")
        #expect(circleCount(canaryWharf) == 4)
        #expect(tickCount(canaryWharf) == 0)
        #expect(connectorCount(canaryWharf) == 3)
        #expect(circleCount(northGreenwichMarker) == 0)
        #expect(tickCount(northGreenwichMarker) == 1)
        let canaryWharfPort = stationLinePort("940GZZLUCYF", .jubilee)
        let northGreenwichPort = stationLinePort("940GZZLUNGW", .jubilee)
        let canaryWharfPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .jubilee else { return nil }
            if segment.fromStationID == "940GZZLUCYF" { return segment.fromPort }
            if segment.toStationID == "940GZZLUCYF" { return segment.toPort }
            return nil
        }
        let northGreenwichPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .jubilee else { return nil }
            if segment.fromStationID == "940GZZLUNGW" { return segment.fromPort }
            if segment.toStationID == "940GZZLUNGW" { return segment.toPort }
            return nil
        }
        #expect(canaryWharf.anchor == canaryWharfPort)
        #expect(northGreenwichMarker.anchor == northGreenwichPort)
        #expect(canaryWharfPorts.allSatisfy { $0 == canaryWharfPort })
        #expect(northGreenwichPorts.allSatisfy { $0 == northGreenwichPort })
        #expect(canaryWharfPort.x < 2_970)
        #expect(northGreenwichPort.x < 3_120)

        let canningApproachSegment = try #require(document.segments.first {
            $0.id == "jubilee:940GZZLUCGT:940GZZLUNGW"
        })
        let canningApproachPath = try #require(document.paths.first {
            $0.id == canningApproachSegment.pathID
        })
        #expect(canningApproachPath.commands.count == 4)
        guard
            case let .move(northGreenwich) = canningApproachPath.commands[0],
            case let .line(horizontalEnd) = canningApproachPath.commands[1],
            case let .line(diagonalEnd) = canningApproachPath.commands[2],
            case let .line(approachEnd) = canningApproachPath.commands[3]
        else {
            Issue.record("Expected one continuous octilinear North Greenwich–Canning Town route")
            return
        }
        #expect(approachEnd == canningTownJubilee)
        #expect(northGreenwich == northGreenwichPort)
        #expect(approachEnd.x - northGreenwich.x > 100)
        #expect(abs(horizontalEnd.y - northGreenwich.y) < 0.01)
        let diagonalDX = diagonalEnd.x - horizontalEnd.x
        let diagonalDY = horizontalEnd.y - diagonalEnd.y
        #expect(diagonalDX > 0)
        #expect(abs(diagonalDX - diagonalDY) < 0.01)
        #expect(abs(diagonalEnd.x - approachEnd.x) < 0.01)
        #expect(diagonalEnd.y > approachEnd.y)

        let raynersLane = try marker("940GZZLURYL")
        #expect(circleCount(raynersLane) == 1)
        #expect(connectorCount(raynersLane) == 0)
        let raynersCentre = try #require(circleCentres(raynersLane).first)
        let raynersMetropolitan = stationLinePort("940GZZLURYL", .metropolitan)
        let raynersPiccadilly = stationLinePort("940GZZLURYL", .piccadilly)
        #expect(hypot(
            raynersMetropolitan.x - raynersPiccadilly.x,
            raynersMetropolitan.y - raynersPiccadilly.y
        ) < 11)
        #expect(hypot(
            raynersCentre.x - raynersMetropolitan.x,
            raynersCentre.y - raynersMetropolitan.y
        ) < 6)
        #expect(hypot(
            raynersCentre.x - raynersPiccadilly.x,
            raynersCentre.y - raynersPiccadilly.y
        ) < 6)

        for stationID in [
            "940GZZLUEAE",
            "940GZZLURSM",
            "940GZZLURSP",
            "940GZZLUICK",
            "940GZZLUHGD",
            "940GZZLUUXB",
        ] {
            let sharedOrdinaryStop = try marker(stationID)
            #expect(circleCount(sharedOrdinaryStop) == 0)
            #expect(connectorCount(sharedOrdinaryStop) == 0)
            #expect(tickCount(sharedOrdinaryStop) == 2)
            let metropolitanPort = stationLinePort(stationID, .metropolitan)
            let piccadillyPort = stationLinePort(stationID, .piccadilly)
            #expect(hypot(
                metropolitanPort.x - piccadillyPort.x,
                metropolitanPort.y - piccadillyPort.y
            ) < 11)
        }

        let ruislip = try marker("940GZZLURSP")
        let ruislipGardens = try marker("940GZZLURSG")
        #expect(ruislip.anchor.x - ruislipGardens.anchor.x > 20)
        #expect(circleCount(ruislipGardens) == 0)
        #expect(connectorCount(ruislipGardens) == 0)
        #expect(tickCount(ruislipGardens) == 1)
        let ruislipPiccadilly = stationLinePort("940GZZLURSP", .piccadilly)
        #expect(ruislipGardens.anchor.y - ruislipPiccadilly.y > 20)

        for segmentID in [
            "metropolitan:940GZZLUEAE:940GZZLURSM",
            "metropolitan:940GZZLUEAE:940GZZLURYL",
            "piccadilly:940GZZLUEAE:940GZZLURSM",
            "piccadilly:940GZZLUEAE:940GZZLURYL",
        ] {
            let segment = try #require(document.segments.first { $0.id == segmentID })
            let points = try commandDestinations(segment.pathID)
            #expect(zip(points, points.dropFirst()).allSatisfy { previous, next in
                next.x >= previous.x && next.y >= previous.y
            })
        }

        for (stationID, expectedTicks) in [
            ("940GZZLUBWT", 2),
            ("940GZZLUSSQ", 2),
            ("940GZZLUSJP", 2),
            ("940GZZLUTMP", 2),
            ("940GZZLUMSH", 2),
            ("940GZZLUBBN", 3),
            ("940GZZLUHSK", 2),
            ("940GZZLUGTR", 2),
        ] {
            let ordinarySharedMarker = try marker(stationID)
            #expect(circleCount(ordinarySharedMarker) == 0)
            #expect(connectorCount(ordinarySharedMarker) == 0)
            #expect(tickCount(ordinarySharedMarker) == expectedTicks)
        }

        let southKensington = try marker("940GZZLUSKS")
        #expect(circleCount(southKensington) == 2)
        #expect(connectorCount(southKensington) == 1)

        for stationID in ["940GZZLUSBM", "940GZZLUGHK", "940GZZLUHSC"] {
            let circlePort = stationLinePort(stationID, .circle)
            let hammersmithCityPort = stationLinePort(stationID, .hammersmithCity)
            #expect(abs(circlePort.y - hammersmithCityPort.y) < 0.001)
        }

        let hammersmithHammersmithCity = try marker("940GZZLUHSC")
        #expect(hammersmithHammersmithCity.lineIDs.contains(.circle))
        #expect(hammersmithHammersmithCity.lineIDs.contains(.hammersmithCity))
        #expect(circleCount(hammersmithHammersmithCity) == 1)
        #expect(connectorCount(hammersmithHammersmithCity) == 0)

        let victoria = try marker("940GZZLUVIC")
        #expect(circleCount(victoria) == 2)
        #expect(connectorCount(victoria) == 1)
        let victoriaCentres = circleCentres(victoria)
        #expect(abs(victoriaCentres[0].x - victoriaCentres[1].x) > 15)
        #expect(abs(victoriaCentres[0].y - victoriaCentres[1].y) > 20)

        let embankment = try marker("940GZZLUEMB")
        #expect(circleCount(embankment) == 2)
        #expect(connectorCount(embankment) == 1)
        let embankmentCentres = circleCentres(embankment)
        #expect(embankmentCentres[0].y < embankmentCentres[1].y - 20)

        let bank = try marker("940GZZLUBNK")
        #expect(circleCount(bank) == 2)
        #expect(connectorCount(bank) == 1)

        let moorgate = try marker("940GZZLUMGT")
        #expect(circleCount(moorgate) == 2)
        #expect(connectorCount(moorgate) == 1)
        let moorgateCentres = circleCentres(moorgate)
        #expect(moorgateCentres[0].x < moorgateCentres[1].x - 20)
        #expect(moorgateCentres[1].y < moorgateCentres[0].y - 20)

        let stepneyGreen = try marker("940GZZLUSGN")
        let mileEnd = try marker("940GZZLUMED")
        #expect(circleCount(stepneyGreen) == 0)
        #expect(connectorCount(stepneyGreen) == 0)
        #expect(tickCount(stepneyGreen) == 2)
        #expect(mileEnd.anchor.x - stepneyGreen.anchor.x > 50)

        let finsburyPark = try marker("940GZZLUFPK")
        #expect(circleCount(finsburyPark) == 2)
        #expect(connectorCount(finsburyPark) == 1)

        for stationID in ["940GZZLUALD", "940GZZLUADE"] {
            let aldgateMarker = try marker(stationID)
            #expect(circleCount(aldgateMarker) == 0)
            #expect(connectorCount(aldgateMarker) == 0)
            #expect(tickCount(aldgateMarker) == 2)
        }

        let londonBridge = try marker("940GZZLULNB")
        #expect(circleCount(londonBridge) == 1)
        #expect(connectorCount(londonBridge) == 0)

        let liverpoolStreet = try marker("940GZZLULVT")
        #expect(circleCount(liverpoolStreet) == 2)
        #expect(connectorCount(liverpoolStreet) == 2)
        #expect(circleCount(try marker("910GLIVSTLL")) == 0)

        for stationID in ["940GZZLUHR5", "940GZZLUHRC", "940GZZLUHR4"] {
            let heathrowMarker = try marker(stationID)
            #expect(circleCount(heathrowMarker) == 1)
            #expect(connectorCount(heathrowMarker) == 0)
        }
        let hattonCross = try marker("940GZZLUHNX")
        #expect(circleCount(hattonCross) == 0)
        #expect(tickCount(hattonCross) == 1)
        #expect(connectorCount(hattonCross) == 0)
    }

    @Test func fullUndergroundNorthernLineIsContinuousAtLondonBridge() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        let bank = try #require(document.segments.first {
            $0.id == "northern:940GZZLUBNK:940GZZLULNB"
        })
        let borough = try #require(document.segments.first {
            $0.id == "northern:940GZZLUBOR:940GZZLULNB"
        })
        #expect(bank.toPort == borough.toPort)
    }

    @Test func fullUndergroundInterchangeTweaksStayConnectedAndAligned() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        func marker(_ stationID: String) throws -> BeckMapStationMarkerRecord {
            try #require(document.stationMarkers.first { $0.stationID == stationID })
        }

        func circles(_ marker: BeckMapStationMarkerRecord) -> [BeckMapPoint] {
            marker.primitives.compactMap {
                if case let .circle(circle) = $0 { return circle.centre }
                return nil
            }
        }

        func connectors(_ marker: BeckMapStationMarkerRecord) -> [BeckMapLinePrimitive] {
            marker.primitives.compactMap {
                if case let .connector(connector) = $0 { return connector }
                return nil
            }
        }

        func hasConnector(
            _ marker: BeckMapStationMarkerRecord,
            between first: BeckMapPoint,
            and second: BeckMapPoint
        ) -> Bool {
            connectors(marker).contains { connector in
                (connector.start == first && connector.end == second)
                    || (connector.start == second && connector.end == first)
            }
        }

        func isFortyFiveDegrees(_ connector: BeckMapLinePrimitive) -> Bool {
            abs(
                abs(connector.end.x - connector.start.x)
                    - abs(connector.end.y - connector.start.y)
            ) < 0.01
        }

        func stationPort(
            _ stationID: String,
            on lineID: TubeLineID
        ) throws -> BeckMapPoint {
            try #require(document.segments.compactMap { segment -> BeckMapPoint? in
                guard segment.lineID == lineID else { return nil }
                if segment.fromStationID == stationID { return segment.fromPort }
                if segment.toStationID == stationID { return segment.toPort }
                return nil
            }.first)
        }

        let kingsCross = try marker("940GZZLUKSX")
        let kingsCrossRoundels = circles(kingsCross)
        let kingsCrossLink = try #require(connectors(kingsCross).first)
        #expect(kingsCrossRoundels.count == 2)
        #expect(kingsCrossLink.end.x < kingsCrossLink.start.x)
        #expect(kingsCrossLink.end.y > kingsCrossLink.start.y)
        #expect(isFortyFiveDegrees(kingsCrossLink))

        let farringdonGeometry = try marker("940GZZLUFCN")
        let farringdonLink = try #require(connectors(farringdonGeometry).first)
        #expect(isFortyFiveDegrees(farringdonLink))
        for lineID in [
            TubeLineID.circle,
            .hammersmithCity,
            .metropolitan,
        ] {
            let kingsCrossPort = try stationPort("940GZZLUKSX", on: lineID)
            let farringdonPort = try stationPort("940GZZLUFCN", on: lineID)
            let barbicanPort = try stationPort("940GZZLUBBN", on: lineID)
            let crossProduct =
                (farringdonPort.x - kingsCrossPort.x)
                    * (barbicanPort.y - kingsCrossPort.y)
                - (farringdonPort.y - kingsCrossPort.y)
                    * (barbicanPort.x - kingsCrossPort.x)
            #expect(abs(crossProduct) < 0.25)
        }

        let edgwareRoad = try marker("940GZZLUERC")
        let edgwareCircles = circles(edgwareRoad)
        #expect(edgwareCircles.count == 2)
        #expect(abs(edgwareCircles[0].x - edgwareCircles[1].x) < 0.001)
        let edgwareLabel = try #require(document.labels.first {
            $0.stationID == edgwareRoad.stationID
        })
        #expect(edgwareLabel.position.y > (edgwareCircles.map(\.y).max() ?? 0))

        let kennington = try marker("940GZZLUKNG")
        let kenningtonConnector = try #require(connectors(kennington).first)
        #expect(abs(
            abs(kenningtonConnector.end.x - kenningtonConnector.start.x)
                - abs(kenningtonConnector.end.y - kenningtonConnector.start.y)
        ) < 0.001)

        let bond = try marker("940GZZLUBND")
        let bondElizabeth = try marker("910GBONDST").anchor
        #expect(circles(bond).contains(bondElizabeth))
        #expect(connectors(bond).contains {
            $0.start == bondElizabeth || $0.end == bondElizabeth
        })
        let bondLabel = try #require(document.labels.first {
            $0.stationID == bond.stationID
        })
        #expect(bondLabel.position.x < bond.anchor.x)
        #expect(bondLabel.position.y < bond.anchor.y)

        let ealing = try marker("940GZZLUEBY")
        let ealingElizabeth = try marker("910GEALINGB")
        let ealingCentral = try stationPort("940GZZLUEBY", on: .central)
        let ealingDistrict = try stationPort("940GZZLUEBY", on: .district)
        let ealingElizabethPort = try stationPort("910GEALINGB", on: .elizabeth)
        #expect(ealingCentral.x == ealingDistrict.x)
        #expect(ealingCentral.x == ealingElizabethPort.x)
        #expect(circles(ealing).contains(ealingElizabethPort))
        #expect(circles(ealing).contains(ealingCentral))
        #expect(circles(ealing).contains(ealingDistrict))
        #expect(ealingElizabeth.anchor == ealingElizabethPort)
        #expect(hasConnector(
            ealing,
            between: ealingElizabethPort,
            and: ealingCentral
        ))
        #expect(hasConnector(
            ealing,
            between: ealingCentral,
            and: ealingDistrict
        ))

        let liverpool = try marker("940GZZLULVT")
        let liverpoolElizabethMarker = try marker("910GLIVSTLL")
        let liverpoolElizabeth = liverpoolElizabethMarker.anchor
        let liverpoolNationalRail = try marker("910GLIVST")
        let moorgate = try marker("940GZZLUMGT")
        let moorgateNorthern = try #require(circles(moorgate).min {
            $0.y < $1.y
        })
        let liverpoolCentral = try stationPort("940GZZLULVT", on: .central)
        #expect(circles(liverpool).count == 2)
        #expect(circles(liverpoolElizabethMarker).isEmpty)
        #expect(circles(liverpoolNationalRail).filter {
            $0 == liverpoolElizabeth
        }.isEmpty)
        #expect(liverpoolCentral == liverpool.anchor)
        #expect(liverpoolCentral != liverpoolElizabeth)
        #expect(circles(liverpool).contains(liverpoolElizabeth))
        #expect(connectors(liverpool).filter {
            $0.start == liverpoolElizabeth || $0.end == liverpoolElizabeth
        }.count == 2)
        #expect(hasConnector(
            liverpool,
            between: liverpoolElizabeth,
            and: moorgateNorthern
        ))
        let moorgateLink = try #require(connectors(liverpool).first {
            $0.start == moorgateNorthern || $0.end == moorgateNorthern
        })
        #expect(isFortyFiveDegrees(moorgateLink))

        let bank = try marker("940GZZLUBNK")
        let dlrBank = try marker("940GZZDLBNK")
        let monument = try marker("940GZZLUMMT")
        let bankCentral = try stationPort("940GZZLUBNK", on: .central)
        let bankWaterloo = try stationPort("940GZZLUBNK", on: .waterlooCity)
        let bankNorthern = try stationPort("940GZZLUBNK", on: .northern)
        let bankDLR = try stationPort("940GZZDLBNK", on: .dlr)
        let monumentRoundel = try #require(circles(monument).first)
        #expect(bankCentral == bankWaterloo)
        #expect(bankNorthern == bankDLR)
        #expect(bankCentral == bank.anchor)
        #expect(bankNorthern == dlrBank.anchor)
        #expect(circles(bank).count == 2)
        #expect(connectors(bank).count == 1)
        #expect(connectors(dlrBank).count == 1)
        #expect(connectors(monument).isEmpty)
        let bankInternalLink = try #require(connectors(bank).first)
        let monumentLink = try #require(connectors(dlrBank).first)
        #expect(isFortyFiveDegrees(bankInternalLink))
        #expect(isFortyFiveDegrees(monumentLink))
        #expect(hasConnector(bank, between: bankCentral, and: bankNorthern))
        #expect(hasConnector(dlrBank, between: dlrBank.anchor, and: monumentRoundel))

        let canningTown = try marker("940GZZLUCGT")
        let dlrCanningTown = try marker("940GZZDLCGT")
        let eastIndia = try marker("940GZZDLEIN")
        #expect(dlrCanningTown.anchor.x > canningTown.anchor.x)
        #expect(dlrCanningTown.anchor.y < canningTown.anchor.y)
        #expect(canningTown.anchor.x - eastIndia.anchor.x > 40)
        #expect(hasConnector(
            dlrCanningTown,
            between: canningTown.anchor,
            and: dlrCanningTown.anchor
        ))
        let canningTownLabel = try #require(document.labels.first {
            $0.stationID == canningTown.stationID
        })
        #expect(canningTownLabel.position.x > canningTown.anchor.x)
        #expect(canningTownLabel.position.y > canningTown.anchor.y)

        let canaryJubilee = try marker("940GZZLUCYF")
        let canaryDLR = try marker("940GZZDLCAN")
        let canaryElizabeth = try marker("910GCANWHRF")
        let westIndiaQuay = try marker("940GZZDLWIQ")
        let canaryRoundels = circles(canaryJubilee)
        #expect(canaryRoundels.contains(canaryJubilee.anchor))
        #expect(canaryRoundels.contains(canaryDLR.anchor))
        #expect(canaryRoundels.contains(canaryElizabeth.anchor))
        #expect(canaryRoundels.contains(westIndiaQuay.anchor))
        #expect(hasConnector(
            canaryJubilee,
            between: canaryJubilee.anchor,
            and: canaryDLR.anchor
        ))
        #expect(hasConnector(
            canaryJubilee,
            between: canaryDLR.anchor,
            and: canaryElizabeth.anchor
        ))
        #expect(hasConnector(
            canaryJubilee,
            between: westIndiaQuay.anchor,
            and: canaryElizabeth.anchor
        ))

        let whitechapel = try marker("940GZZLUWPL")
        let whitechapelElizabeth = try marker("910GWCHAPXR")
        #expect(circles(whitechapel).contains(whitechapelElizabeth.anchor))
        #expect(hasConnector(
            whitechapel,
            between: whitechapel.anchor,
            and: whitechapelElizabeth.anchor
        ))

        let stepneyGreen = try marker("940GZZLUSGN")
        let mileEnd = try marker("940GZZLUMED")
        #expect(stepneyGreen.anchor.x > 2_850)
        #expect(mileEnd.anchor.x - stepneyGreen.anchor.x > 50)
        let stepneyGreenLabel = try #require(document.labels.first {
            $0.stationID == stepneyGreen.stationID
        })
        #expect(stepneyGreenLabel.position.x > stepneyGreen.anchor.x)
        #expect(stepneyGreenLabel.position.y > stepneyGreen.anchor.y)
        let mileEndLabel = try #require(document.labels.first {
            $0.stationID == mileEnd.stationID
        })
        let mileEndTopRoundel = try #require(circles(mileEnd).map(\.y).min())
        #expect(mileEndLabel.position.y < mileEndTopRoundel - 20)

        let farringdon = try marker("940GZZLUFCN")
        let farringdonElizabeth = try marker("910GFRNDXR")
        #expect(circles(farringdon).count == 2)
        #expect(circles(farringdon).contains(farringdon.anchor))
        #expect(circles(farringdon).contains(farringdonElizabeth.anchor))
        #expect(hasConnector(
            farringdon,
            between: farringdon.anchor,
            and: farringdonElizabeth.anchor
        ))

        let tottenhamCourtRoad = try marker("940GZZLUTCR")
        let tottenhamElizabeth = try marker("910GTOTCTRD")
        #expect(tottenhamElizabeth.anchor.x - tottenhamCourtRoad.anchor.x > 20)
        #expect(circles(tottenhamCourtRoad).contains(tottenhamCourtRoad.anchor))
        #expect(circles(tottenhamCourtRoad).contains(tottenhamElizabeth.anchor))
        #expect(hasConnector(
            tottenhamCourtRoad,
            between: tottenhamCourtRoad.anchor,
            and: tottenhamElizabeth.anchor
        ))
        let tottenhamNorthernPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .northern else { return nil }
            if segment.fromStationID == tottenhamCourtRoad.stationID { return segment.fromPort }
            if segment.toStationID == tottenhamCourtRoad.stationID { return segment.toPort }
            return nil
        }
        #expect(tottenhamNorthernPorts.allSatisfy { $0 == tottenhamElizabeth.anchor })
    }

    @Test func fullUndergroundWaterlooLabelStaysNearItsMarker() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        let marker = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWLO"
        })
        let label = try #require(document.labels.first {
            $0.stationID == "940GZZLUWLO"
        })
        #expect(hypot(
            label.position.x - marker.anchor.x,
            label.position.y - marker.anchor.y
        ) < 45)
    }

    @Test func fullUndergroundLabelsHaveProgressiveVisibilityTiers() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let labelsByStationID = Dictionary(
            uniqueKeysWithValues: document.labels.map { ($0.stationID, $0) }
        )

        for stationID in ["940GZZLUVIC", "940GZZLUSTD", "940GZZLUCYF"] {
            #expect(labelsByStationID[stationID]?.effectiveVisibilityTier == .overview)
        }
        #expect(labelsByStationID["940GZZLUWOF"]?.effectiveVisibilityTier == .network)
        #expect(labelsByStationID["940GZZLUSWN"]?.effectiveVisibilityTier == .local)
        #expect(labelsByStationID["940GZZDLDEV"]?.effectiveVisibilityTier == .minor)

        let tierCounts = Dictionary(grouping: document.labels, by: \.effectiveVisibilityTier)
            .mapValues(\.count)
        #expect(tierCounts[.overview] == 17)
        #expect(tierCounts[.network] == 66)
        #expect(tierCounts[.local] == 192)
        #expect(tierCounts[.minor] == 183)
    }

    @Test func splitPhysicalHubsShareTheirCanonicalLabel() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let canaryWharf = try #require(document.labels.first {
            $0.stationID == "940GZZLUCYF"
        })
        let stratford = try #require(document.labels.first {
            $0.stationID == "940GZZLUSTD"
        })

        #expect(canaryWharf.represents(stationID: "910GCANWHRF"))
        #expect(canaryWharf.represents(stationID: "940GZZDLCAN"))
        #expect(stratford.represents(stationID: "910GSTFD"))
        #expect(stratford.represents(stationID: "940GZZDLSTD"))
        #expect(!stratford.represents(stationID: "940GZZLUVIC"))

        let claphamJunctionLabels = document.labels.filter { $0.text == "Clapham Junction" }
        let claphamJunction = try #require(claphamJunctionLabels.first)
        #expect(claphamJunctionLabels.count == 1)
        #expect(claphamJunction.effectiveVisibilityTier == .network)
        #expect(claphamJunction.represents(stationID: "910GCLPHMJ1"))
        #expect(claphamJunction.represents(stationID: "910GCLPHMJC"))
    }

    @Test func claphamJunctionRoundelsHaveAVisibleConnector() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let claphamMarkers = document.stationMarkers.filter {
            ["910GCLPHMJ1", "910GCLPHMJC"].contains($0.stationID)
        }
        let connectors: [BeckMapLinePrimitive] = claphamMarkers
            .flatMap(\.primitives)
            .compactMap { primitive in
                guard case let .connector(connector) = primitive else { return nil }
                return connector
            }

        #expect(claphamMarkers.count == 2)
        #expect(connectors == [
            BeckMapLinePrimitive(
                start: BeckMapPoint(x: 1_509.797, y: 2_295.328),
                end: BeckMapPoint(x: 1_477.407, y: 2_266.062),
                width: 7.5
            ),
        ])
    }

    @Test func labelVisibilityPolicyRevealsDetailProgressively() {
        #expect(!BeckMapLabelVisibilityPolicy.shows(.overview, at: 0.08))
        #expect(BeckMapLabelVisibilityPolicy.shows(
            .overview,
            at: BeckMapLabelVisibilityPolicy.overviewMinimumCameraScale
        ))
        #expect(!BeckMapLabelVisibilityPolicy.shows(.network, at: 0.16))
        #expect(BeckMapLabelVisibilityPolicy.shows(
            .network,
            at: BeckMapLabelVisibilityPolicy.networkMinimumCameraScale
        ))
        #expect(!BeckMapLabelVisibilityPolicy.shows(
            .local,
            at: BeckMapLabelVisibilityPolicy.localMinimumCameraScale - 0.01
        ))
        #expect(BeckMapLabelVisibilityPolicy.shows(
            .local,
            at: BeckMapLabelVisibilityPolicy.localMinimumCameraScale
        ))
        #expect(!BeckMapLabelVisibilityPolicy.shows(
            .minor,
            at: BeckMapLabelVisibilityPolicy.minorMinimumCameraScale - 0.01
        ))
        #expect(BeckMapLabelVisibilityPolicy.shows(
            .minor,
            at: BeckMapLabelVisibilityPolicy.minorMinimumCameraScale
        ))
    }

    @Test func compactStationLabelsAppearBeforeTheOldHighZoomThresholds() {
        #expect(BeckMapLabelVisibilityPolicy.shows(.network, at: 0.18))
        #expect(BeckMapLabelVisibilityPolicy.shows(.local, at: 0.3))
        #expect(BeckMapLabelVisibilityPolicy.shows(.minor, at: 0.42))
        #expect(BeckMapLabelVisibilityPolicy.minorMinimumCameraScale < 0.5)
    }

    @Test func stationLabelFontsGrowContinuouslyWithAvailableZoomSpace() {
        for tier in [
            BeckMapLabelVisibilityTier.overview,
            .network,
            .local,
            .minor,
        ] {
            let compact = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: BeckMapLabelVisibilityPolicy.fontGrowthStartCameraScale
            )
            let intermediate = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: 0.6
            )
            let fullSize = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: BeckMapLabelVisibilityPolicy.fullSizeFontCameraScale
            )

            #expect(compact < intermediate)
            #expect(intermediate < fullSize)
            #expect(BeckMapLabelVisibilityPolicy.fontSize(for: tier, at: 0.1) == compact)
            #expect(BeckMapLabelVisibilityPolicy.fontSize(for: tier, at: 2) == fullSize)
        }

        #expect(BeckMapLabelVisibilityPolicy.fontSize(for: .minor, at: 0.42) < 10)
        #expect(BeckMapLabelVisibilityPolicy.fontSize(for: .overview, at: 0.42)
            > BeckMapLabelVisibilityPolicy.fontSize(for: .minor, at: 0.42))
    }

    @Test func reportedHighZoomStationsHaveAuthoredLabels() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let labelsByStationID = Dictionary(
            uniqueKeysWithValues: document.labels.map { ($0.stationID, $0) }
        )

        #expect(labelsByStationID["940GZZLURYL"]?.text == "Rayners Lane")
        #expect(labelsByStationID["940GZZLURYL"]?.effectiveVisibilityTier == .network)
        #expect(labelsByStationID["910GEMRSPKH"]?.text == "Emerson Park")
        #expect(labelsByStationID["910GEMRSPKH"]?.effectiveVisibilityTier == .minor)
        for stationID in [
            "940GZZLUCPN",
            "940GZZLUCPC",
            "940GZZLUCPS",
            "940GZZLUTBC",
            "940GZZLUTBY",
            "940GZZLUCSD",
            "940GZZLUSWN",
            "940GZZLUMDN",
        ] {
            #expect(labelsByStationID[stationID]?.effectiveVisibilityTier == .local)
        }
    }

    @Test func northwestWalkingInterchangeLabelsUseOfficialZonesAndPriority() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        let labels = Dictionary(
            uniqueKeysWithValues: document.labels.map { ($0.stationID, $0) }
        )
        let markers = Dictionary(
            uniqueKeysWithValues: document.stationMarkers.map { ($0.stationID, $0) }
        )

        let westHampstead = try #require(labels["940GZZLUWHP"])
        #expect(westHampstead.text == "West\nHampstead")
        #expect(westHampstead.alignment == .centre)
        #expect(westHampstead.effectiveVisibilityTier == .network)
        #expect(westHampstead.priority >= 10)
        #expect(westHampstead.associatedStationIDs?.contains("910GWHMDSTD") == true)
        let westHampsteadMildmay = try #require(markers["910GWHMDSTD"])
        #expect(westHampstead.position.y < westHampsteadMildmay.anchor.y)

        let finchleyFrognal = try #require(labels["910GFNCHLYR"])
        #expect(finchleyFrognal.alignment == .leading)
        let finchleyFrognalMarker = try #require(markers["910GFNCHLYR"])
        #expect(finchleyFrognal.position.y > finchleyFrognalMarker.anchor.y)

        let finchleyRoad = try #require(labels["940GZZLUFYR"])
        #expect(finchleyRoad.text == "Finchley\nRoad")
        #expect(finchleyRoad.alignment == .trailing)
        let finchleyRoadMarker = try #require(markers["940GZZLUFYR"])
        #expect(finchleyRoad.position.x < finchleyRoadMarker.anchor.x)
        #expect(finchleyRoad.position.y > finchleyRoadMarker.anchor.y)
    }

    @Test func labelCollisionResolverRejectsMarkersAndEarlierLabels() {
        let frame = CGRect(x: 20, y: 20, width: 80, height: 24)

        #expect(!BeckMapLabelCollisionResolver.accepts(
            frame,
            markerBlockers: [BeckMapLabelBlocker(
                stationID: "other",
                frame: CGRect(x: 90, y: 25, width: 20, height: 20)
            )],
            lineBlockers: [],
            occupied: []
        ))
        #expect(!BeckMapLabelCollisionResolver.accepts(
            frame,
            markerBlockers: [],
            lineBlockers: [],
            occupied: [CGRect(x: 40, y: 30, width: 30, height: 20)]
        ))
        #expect(BeckMapLabelCollisionResolver.accepts(
            frame,
            markerBlockers: [BeckMapLabelBlocker(
                stationID: "other",
                frame: CGRect(x: 120, y: 20, width: 20, height: 20)
            )],
            lineBlockers: [],
            occupied: [CGRect(x: 20, y: 60, width: 80, height: 20)]
        ))
        #expect(!BeckMapLabelCollisionResolver.accepts(
            frame,
            markerBlockers: [BeckMapLabelBlocker(
                stationID: "station",
                frame: CGRect(x: 40, y: 20, width: 20, height: 20)
            )],
            lineBlockers: [],
            occupied: []
        ))
        #expect(!BeckMapLabelCollisionResolver.accepts(
            frame,
            markerBlockers: [],
            lineBlockers: [BeckMapLineBlocker(
                start: CGPoint(x: 0, y: 32),
                end: CGPoint(x: 140, y: 32),
                clearance: 4
            )],
            occupied: []
        ))
    }

    @Test func stationLabelLayoutKeepsTextOffRouteLines() throws {
        let boundsByAlignment = Dictionary(uniqueKeysWithValues:
            [BeckMapLabelAlignment.leading, .centre, .trailing].map { alignment in
                (alignment, BeckMapLabelBounds.backgroundBounds(
                    textSize: CGSize(width: 110, height: 24),
                    alignment: alignment,
                    horizontalPadding: 2,
                    verticalPadding: 2
                ))
            }
        )
        let route = BeckMapLineBlocker(
            start: CGPoint(x: 0, y: 240),
            end: CGPoint(x: 320, y: 240),
            clearance: 5
        )
        let placements = StationLabelLayoutEngine.layout(
            inputs: [StationLabelLayoutInput(
                id: "clapham-junction",
                priority: 10,
                tier: .network,
                selected: false,
                stationScreenPosition: CGPoint(x: 160, y: 240),
                markerFrame: CGRect(x: 150, y: 230, width: 20, height: 20),
                preferredAlignment: .leading,
                screenOffset: CGVector(dx: 20, dy: 0),
                rotation: .identity,
                boundsByAlignment: boundsByAlignment
            )],
            viewport: CGRect(x: 0, y: 80, width: 320, height: 340),
            markerBlockers: [BeckMapLabelBlocker(
                stationID: "clapham-junction",
                frame: CGRect(x: 150, y: 230, width: 20, height: 20)
            )],
            lineBlockers: [route]
        )

        let placement = try #require(placements.first)
        #expect(!route.intersects(placement.collisionFrame))
    }

    @Test func stationLabelLayoutLetsHigherPriorityLabelsWin() throws {
        let boundsByAlignment = Dictionary(uniqueKeysWithValues:
            [BeckMapLabelAlignment.leading, .centre, .trailing].map { alignment in
                (alignment, BeckMapLabelBounds.backgroundBounds(
                    textSize: CGSize(width: 260, height: 24),
                    alignment: alignment,
                    horizontalPadding: 2,
                    verticalPadding: 2
                ))
            }
        )
        func input(id: String, priority: Int, tier: BeckMapLabelVisibilityTier) -> StationLabelLayoutInput {
            StationLabelLayoutInput(
                id: id,
                priority: priority,
                tier: tier,
                selected: false,
                stationScreenPosition: CGPoint(x: 150, y: 150),
                markerFrame: CGRect(x: 140, y: 140, width: 20, height: 20),
                preferredAlignment: .centre,
                screenOffset: CGVector(dx: 0, dy: -10),
                rotation: .identity,
                boundsByAlignment: boundsByAlignment
            )
        }
        let placements = StationLabelLayoutEngine.layout(
            inputs: [
                input(id: "ordinary", priority: 5, tier: .local),
                input(id: "major", priority: 40, tier: .overview),
            ],
            viewport: CGRect(x: 0, y: 90, width: 300, height: 120),
            markerBlockers: [BeckMapLabelBlocker(
                stationID: "shared",
                frame: CGRect(x: 140, y: 140, width: 20, height: 20)
            )],
            lineBlockers: [BeckMapLineBlocker(
                start: CGPoint(x: 0, y: 180),
                end: CGPoint(x: 300, y: 180),
                clearance: 5
            )]
        )

        #expect(placements.map(\.labelID) == ["major"])
    }

    @Test func stationLabelViewportProtectsMapChrome() {
        let viewport = StationLabelLayoutEngine.availableViewport(
            in: CGSize(width: 390, height: 844)
        )

        #expect(viewport.minX == StationLabelLayoutEngine.horizontalViewportInset)
        #expect(viewport.minY > 80)
        #expect(viewport.maxY < 770)
    }

    @Test func labelPlacementCandidatesPreserveAuthoredSideAndEdgeGap() {
        let station = CGPoint(x: 200, y: 300)
        let markerFrame = CGRect(x: 190, y: 290, width: 20, height: 20)
        let labelBounds = CGRect(x: -80, y: -12, width: 80, height: 24)
        let candidates = BeckMapLabelPlacementResolver.candidates(
            stationScreenPosition: station,
            markerFrame: markerFrame,
            labelBounds: labelBounds,
            screenOffset: CGVector(dx: -110, dy: 4),
            authoredAlignment: .trailing
        )

        let preferred = candidates.first
        #expect(preferred?.alignment == .trailing)
        #expect(abs((preferred?.position.x ?? 0) + labelBounds.maxX
            - (markerFrame.minX - BeckMapLabelPlacementResolver.preferredGap)) < 0.001)
        #expect(abs((preferred?.position.y ?? 0) - 304) < 0.001)
        #expect(candidates.allSatisfy { $0.alignment == .trailing })
        #expect(candidates.allSatisfy {
            $0.position.x + labelBounds.maxX
                <= markerFrame.minX - BeckMapLabelPlacementResolver.preferredGap + 0.001
        })
    }

    @Test func labelPlacementFlipsSidesAtTheViewportEdge() throws {
        let viewport = CGRect(x: 0, y: 0, width: 320, height: 480)
        let station = CGPoint(x: 12, y: 180)
        let markerFrame = CGRect(x: 2, y: 170, width: 20, height: 20)
        let options = BeckMapLabelPlacementResolver.placementOptions(
            authoredAlignment: .trailing,
            screenOffset: CGVector(dx: -40, dy: 0)
        )
        let placement = try #require(options.lazy.compactMap { option -> BeckMapLabelPlacementCandidate? in
            let bounds = BeckMapLabelBounds.backgroundBounds(
                textSize: CGSize(width: 120, height: 24),
                alignment: option.alignment,
                horizontalPadding: 2,
                verticalPadding: 2
            )
            return BeckMapLabelPlacementResolver.candidates(
                stationScreenPosition: station,
                markerFrame: markerFrame,
                labelBounds: bounds,
                screenOffset: option.screenOffset,
                authoredAlignment: option.alignment
            ).first { candidate in
                viewport.contains(bounds.offsetBy(
                    dx: candidate.position.x,
                    dy: candidate.position.y
                ))
            }
        }.first)

        #expect(placement.alignment == .leading)
    }

    @Test func reportedLabelsStayMarkerAttachedAcrossCameraScales() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        for stationID in [
            "940GZZLUTBC", // Tooting Bec
            "940GZZLUTBY", // Tooting Broadway
            "940GZZLUWSM", // Westminster
            "940GZZLURYL", // Rayners Lane
            "910GEMRSPKH", // Emerson Park
        ] {
            let marker = try #require(document.stationMarkers.first { $0.stationID == stationID })
            let label = try #require(document.labels.first { $0.stationID == stationID })
            for scale in [CGFloat(0.1), 1, 4] {
                let station = CGPoint(x: marker.anchor.x * scale, y: marker.anchor.y * scale)
                let markerFrame = CGRect(
                    x: station.x - 10,
                    y: station.y - 10,
                    width: 20,
                    height: 20
                )
                let labelBounds = BeckMapLabelBounds.backgroundBounds(
                    textSize: CGSize(width: 160, height: 24),
                    alignment: label.alignment,
                    horizontalPadding: 2,
                    verticalPadding: 2
                )
                let candidate = try #require(BeckMapLabelPlacementResolver.candidates(
                    stationScreenPosition: station,
                    markerFrame: markerFrame,
                    labelBounds: labelBounds,
                    screenOffset: CGVector(
                        dx: (label.position.x - marker.anchor.x) * scale,
                        dy: (label.position.y - marker.anchor.y) * scale
                    ),
                    authoredAlignment: label.alignment
                ).first)
                let labelFrame = labelBounds.offsetBy(
                    dx: candidate.position.x,
                    dy: candidate.position.y
                )
                #expect(candidate.alignment == label.alignment)
                #expect(!labelFrame.intersects(markerFrame))
                switch candidate.alignment {
                case .leading:
                    #expect(abs(labelFrame.minX
                        - (markerFrame.maxX + BeckMapLabelPlacementResolver.preferredGap)) < 0.001)
                case .trailing:
                    #expect(abs(labelFrame.maxX
                        - (markerFrame.minX - BeckMapLabelPlacementResolver.preferredGap)) < 0.001)
                case .centre where label.position.y < marker.anchor.y:
                    #expect(abs(labelFrame.maxY
                        - (markerFrame.minY - BeckMapLabelPlacementResolver.preferredGap)) < 0.001)
                case .centre:
                    #expect(abs(labelFrame.minY
                        - (markerFrame.maxY + BeckMapLabelPlacementResolver.preferredGap)) < 0.001)
                }
            }
        }
    }

    @Test func labelPlacementFindsClearSpaceAroundAnInterchangeCrossing() throws {
        let station = CGPoint(x: 100, y: 100)
        let marker = BeckMapLabelBlocker(
            stationID: "station",
            frame: CGRect(x: 80, y: 80, width: 40, height: 40)
        )
        let routes = [
            BeckMapLineBlocker(
                start: CGPoint(x: 88, y: 0),
                end: CGPoint(x: 88, y: 200),
                clearance: 3
            ),
        ]
        let labelBounds = CGRect(x: -82, y: -13, width: 82, height: 26)
        let candidates = BeckMapLabelPlacementResolver.candidates(
            stationScreenPosition: station,
            markerFrame: marker.frame,
            labelBounds: labelBounds,
            screenOffset: CGVector(dx: -20, dy: 0),
            authoredAlignment: .trailing
        )
        let placement = try #require(candidates.first { candidate in
            let frame = labelBounds.offsetBy(
                dx: candidate.position.x,
                dy: candidate.position.y
            )
            return BeckMapLabelCollisionResolver.accepts(
                frame,
                markerBlockers: [marker],
                lineBlockers: routes,
                occupied: []
            )
        })

        #expect(placement.alignment == .trailing)
        #expect(placement.position.x + labelBounds.maxX < marker.frame.minX)
    }

    @Test func fullUndergroundCircleBranchesShareTheGloucesterRoadPort() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        let highStreetKensington = try #require(document.segments.first {
            $0.id == "circle:940GZZLUGTR:940GZZLUHSK"
        })
        let southKensington = try #require(document.segments.first {
            $0.id == "circle:940GZZLUGTR:940GZZLUSKS"
        })
        #expect(highStreetKensington.fromPort == southKensington.fromPort)
    }

    @Test func validAuthoredDocumentPassesStrictValidation() throws {
        let graph = try TubeGraph.bundled()
        let document = try makeDocument(graph: graph)

        try repository.validate(document, against: graph)
    }

    @Test func bundledHeathrowDocumentLoadsAsAuthoredGeometry() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(document.segments.contains { $0.id == BeckMapRepository.supplementalHeathrowSegmentID })
    }

    @Test func bundledCentralBackboneLoadsWithSharedCorridorsAndComplexPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralBackbone, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)).isSuperset(of: [
            .circle, .hammersmithCity, .metropolitan, .northern, .district, .waterlooCity,
        ]))
        #expect(document.segments.contains {
            $0.id == "northern:940GZZLUBNK:940GZZLULNB"
                && $0.fromPort != nil
                && $0.toPort != nil
        })
        #expect(document.stationMarkers.flatMap(\.primitives).contains {
            if case .tick = $0 { return true }
            return false
        })
    }

    @Test func bundledCentralCoreJoinLoadsExactTfLPathsAndLineSpecificPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralCoreJoin, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [
            .bakerloo, .central, .circle, .district, .jubilee,
            .northern, .piccadilly, .victoria,
        ])
        #expect(document.segments.count == 45)
        #expect(document.stationMarkers.count == 26)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })
        #expect(document.segments.contains {
            $0.id == "jubilee:940GZZLUWLO:940GZZLUWSM"
                && $0.fromPort != nil
                && $0.toPort != nil
        })
    }

    @Test func bundledEastConnectorLoadsExactTfLPathsAndLineSpecificPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .eastConnector, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [
            .central, .circle, .district, .hammersmithCity,
            .jubilee, .metropolitan, .northern,
        ])
        #expect(document.segments.count == 31)
        #expect(document.stationMarkers.count == 24)
        #expect(document.segments.contains {
            $0.id == "central:940GZZLUBLG:940GZZLULVT"
                && $0.fromPort != nil
                && $0.toPort != nil
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLULVT"
                && $0.primitives.contains { if case .connector = $0 { return true }; return false }
        })
    }

    @Test func bundledNorthConnectorLoadsExactTfLBranchesAndInterchangePorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .northConnector, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [.northern, .piccadilly, .victoria])
        #expect(document.segments.count == 43)
        #expect(document.stationMarkers.count == 41)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUEUS"
                && $0.primitives.contains { if case .connector = $0 { return true }; return false }
        })
    }

    @Test func bundledSouthConnectorLoadsExactTfLBranchesAndInterchangePorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .southConnector, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [.bakerloo, .northern, .victoria])
        #expect(document.segments.count == 23)
        #expect(document.stationMarkers.count == 23)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUKNG"
                && $0.primitives.contains { if case .connector = $0 { return true }; return false }
        })

        let kennington = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUKNG"
        })
        #expect(kennington.primitives.filter {
            if case .circle = $0 { return true }
            return false
        }.count == 2)
        #expect(kennington.primitives.filter {
            if case .connector = $0 { return true }
            return false
        }.count == 1)

        let oval = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUOVL"
        })
        #expect(oval.primitives.count == 1)
        #expect(oval.primitives.contains { if case .tick = $0 { return true }; return false })

        let elephant = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUEAC"
        })
        #expect(elephant.primitives.filter {
            if case .circle = $0 { return true }
            return false
        }.count == 1)
        #expect(!elephant.primitives.contains {
            if case .connector = $0 { return true }
            return false
        })

        let kenningtonToElephant = try #require(document.segments.first {
            $0.id == "northern:940GZZLUEAC:940GZZLUKNG"
        })
        let elephantToBorough = try #require(document.segments.first {
            $0.id == "northern:940GZZLUBOR:940GZZLUEAC"
        })
        let bakerlooToElephant = try #require(document.segments.first {
            $0.id == "bakerloo:940GZZLUEAC:940GZZLULBN"
        })
        #expect(kenningtonToElephant.toPort == elephantToBorough.fromPort)
        let northernPort = try #require(kenningtonToElephant.toPort)
        let bakerlooPort = try #require(bakerlooToElephant.fromPort)
        #expect(hypot(
            northernPort.x - bakerlooPort.x,
            northernPort.y - bakerlooPort.y
        ) < 0.1)
    }

    @Test func bundledNorthwestConnectorLoadsEveryTfLBranchAndSharedPort() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .northwestConnector, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [.bakerloo, .jubilee, .metropolitan])
        #expect(document.segments.count == 56)
        #expect(document.stationMarkers.count == 53)
        #expect(document.routes.count == 6)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUBST"
                && Set($0.lineIDs) == [.bakerloo, .jubilee, .metropolitan]
                && $0.primitives.contains { if case .connector = $0 { return true }; return false }
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUWYP"
                && Set($0.lineIDs) == [.jubilee, .metropolitan]
        })
    }

    @Test func bundledWesternFanLoadsEveryTfLBranchAndSharedPort() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .westernFan, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [
            .central, .circle, .district, .hammersmithCity, .piccadilly,
        ])
        #expect(document.segments.count == 103)
        #expect(document.stationMarkers.count == 78)
        #expect(document.routes.count == 13)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUEBY"
                && Set($0.lineIDs) == [.central, .district]
                && $0.primitives.contains { if case .connector = $0 { return true }; return false }
        })
        #expect(document.stationMarkers.contains {
            $0.stationID == "940GZZLUECT"
                && Set($0.lineIDs) == [.district, .piccadilly]
        })

        let northActon = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUNAN"
        })
        #expect(northActon.primitives.count == 1)
        #expect(northActon.primitives.contains { if case .tick = $0 { return true }; return false })

        let ordinarySharedStations = [
            "940GZZLUGHK", "940GZZLUSBM", "940GZZLULRD",
            "940GZZLULAD", "940GZZLUWSP", "940GZZLURYO",
        ]
        for stationID in ordinarySharedStations {
            let marker = try #require(document.stationMarkers.first { $0.stationID == stationID })
            #expect(marker.primitives.count == 2)
            #expect(marker.primitives.allSatisfy { if case .tick = $0 { return true }; return false })
        }

        let whiteCity = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWCY"
        })
        #expect(whiteCity.primitives.contains {
            if case .walkingConnector = $0 { return true }
            return false
        })
        #expect(whiteCity.primitives.contains { if case .circle = $0 { return true }; return false })

        let woodLane = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWLA"
        })
        #expect(woodLane.primitives.count == 1)
        #expect(woodLane.primitives.contains { if case .circle = $0 { return true }; return false })

        #expect(document.segments.contains {
            $0.lineID == .piccadilly
                && Set([$0.fromStationID, $0.toStationID]) == ["940GZZLUECT", "940GZZLUGTR"]
        })
        #expect(document.segments.contains {
            $0.lineID == .district
                && Set([$0.fromStationID, $0.toStationID]) == ["940GZZLUECT", "940GZZLUGTR"]
        })
    }

    @Test func bundledEasternFanLoadsEveryTfLBranchAndCorrectSharedStations() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .easternFan, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [
            .central, .district, .hammersmithCity, .jubilee,
        ])
        #expect(document.segments.count == 46)
        #expect(document.stationMarkers.count == 39)
        #expect(document.routes.count == 6)
        #expect(document.paths.flatMap(\.commands).contains {
            if case .cubic = $0 { return true }
            return false
        })

        for stationID in ["940GZZLULYS", "940GZZLUWOF"] {
            let marker = try #require(document.stationMarkers.first { $0.stationID == stationID })
            #expect(marker.primitives.count == 1)
            #expect(marker.primitives.filter { if case .circle = $0 { return true }; return false }.count == 1)
            #expect(!marker.primitives.contains { if case .connector = $0 { return true }; return false })
        }

        for stationID in ["940GZZLUBWR", "940GZZLUBBB", "940GZZLUPLW", "940GZZLUUPK", "940GZZLUEHM"] {
            let marker = try #require(document.stationMarkers.first { $0.stationID == stationID })
            #expect(marker.primitives.count == 2)
            #expect(marker.primitives.allSatisfy { if case .tick = $0 { return true }; return false })
        }

        let westHam = try #require(document.stationMarkers.first { $0.stationID == "940GZZLUWHM" })
        #expect(Set(westHam.lineIDs) == [.district, .hammersmithCity, .jubilee])
        #expect(westHam.primitives.contains { if case .circle = $0 { return true }; return false })
    }

    @Test func bundledCentralCompletionLoadsTheFinalFiveSemanticSegments() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralCompletion, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [.bakerloo, .jubilee, .victoria])
        #expect(document.segments.count == 5)
        #expect(document.stationMarkers.count == 6)
        #expect(document.routes.count == 3)

        let bakerStreet = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUBST"
        })
        #expect(Set(bakerStreet.lineIDs) == [.bakerloo, .jubilee])
        #expect(bakerStreet.primitives.contains { if case .connector = $0 { return true }; return false })

        let regentsPark = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLURGP"
        })
        #expect(regentsPark.primitives.count == 1)
        #expect(regentsPark.primitives.contains { if case .tick = $0 { return true }; return false })
    }

    @Test func bundledWestConnectorLoadsWithSharedCorridorsAndComplexPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .westConnector, graph: graph)

        #expect(document.schemaVersion == .current)
        #expect(document.geometryStatus == .authored)
        #expect(Set(document.segments.map(\.lineID)) == [.piccadilly, .district, .circle])
        #expect(document.segments.count == 27)
        #expect(document.stationMarkers.count == 21)
        #expect(document.segments.contains {
            $0.id == "piccadilly:940GZZLUGTR:940GZZLUSKS"
                && $0.fromPort != nil
                && $0.toPort != nil
        })
    }

    @Test func debugBuildBundlesTheHeathrowTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheCentralTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralBackbone, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheCentralCoreJoinTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralCoreJoin, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheEastConnectorTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .eastConnector, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheNorthConnectorTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .northConnector, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheSouthConnectorTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .southConnector, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheNorthwestConnectorTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .northwestConnector, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheWesternFanTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .westernFan, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheEasternFanTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .easternFan, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheCentralCompletionTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .centralCompletion, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func debugBuildBundlesTheWestConnectorTraceReference() throws {
        #if DEBUG
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .westConnector, graph: graph)
        let reference = document.debugReference

        #expect(Bundle.main.url(
            forResource: reference.resourceName,
            withExtension: reference.resourceExtension
        ) != nil)
        #endif
    }

    @Test func prototypeGeometryCannotCrossTheRepositoryBoundary() throws {
        let graph = try TubeGraph.bundled()
        let document = try makeDocument(graph: graph, geometryStatus: .prototype)

        #expect(throws: BeckMapRepositoryError.validationFailed(.geometryIsNotAuthored(.prototype))) {
            try repository.validate(document, against: graph)
        }
    }

    @Test func pathMustBeginWithMoveAndRemainInsideTheCanvas() throws {
        let graph = try TubeGraph.bundled()
        let invalidOrder = try makeDocument(
            graph: graph,
            commands: [.line(to: BeckMapPoint(x: 80, y: 50)), .close]
        )
        #expect(throws: BeckMapRepositoryError.validationFailed(
            .invalidPathOrder(pathID: "heathrow.path", commandIndex: 0)
        )) {
            try repository.validate(invalidOrder, against: graph)
        }

        let outsideCanvas = try makeDocument(
            graph: graph,
            commands: [
                .move(to: BeckMapPoint(x: 20, y: 50)),
                .line(to: BeckMapPoint(x: 101, y: 50)),
            ]
        )
        #expect(throws: BeckMapRepositoryError.validationFailed(
            .coordinateOutOfBounds(
                context: "path heathrow.path line",
                point: BeckMapPoint(x: 101, y: 50)
            )
        )) {
            try repository.validate(outsideCanvas, against: graph)
        }
    }

    @Test func duplicateAndMissingReferencesAreRejected() throws {
        let graph = try TubeGraph.bundled()
        let duplicatePath = try makeDocument(graph: graph, duplicatePath: true)
        #expect(throws: BeckMapRepositoryError.validationFailed(
            .duplicateIdentifier(kind: "path", identifier: "heathrow.path")
        )) {
            try repository.validate(duplicatePath, against: graph)
        }

        let missingPath = try makeDocument(graph: graph, segmentPathID: "absent.path")
        #expect(throws: BeckMapRepositoryError.validationFailed(
            .missingPath(segmentID: "piccadilly:940GZZLUHNX:940GZZLUHRC", pathID: "absent.path")
        )) {
            try repository.validate(missingPath, against: graph)
        }
    }

    @Test func onlyTheDocumentedHeathrowSupplementMayExtendTheGraph() throws {
        let graph = try TubeGraph.bundled()
        let supplement = try makeDocument(
            graph: graph,
            segmentID: BeckMapRepository.supplementalHeathrowSegmentID,
            fromStationID: "940GZZLUHNX",
            toStationID: "940GZZLUHR4"
        )
        try repository.validate(supplement, against: graph)

        let unapproved = try makeDocument(
            graph: graph,
            segmentID: "piccadilly:940GZZLUHR4:940GZZLUHR5",
            fromStationID: "940GZZLUHR4",
            toStationID: "940GZZLUHR5"
        )
        #expect(throws: BeckMapRepositoryError.validationFailed(
            .unknownSemanticSegment(segmentID: "piccadilly:940GZZLUHR4:940GZZLUHR5")
        )) {
            try repository.validate(unapproved, against: graph)
        }
    }

    @Test func routeSegmentsMustJoinTheirAdjacentStations() throws {
        let graph = try TubeGraph.bundled()
        let document = try makeDocument(
            graph: graph,
            routeStationIDs: ["940GZZLUHRC", "940GZZLUHR4"]
        )

        #expect(throws: BeckMapRepositoryError.validationFailed(
            .routeAdjacencyMismatch(
                routeID: "piccadilly.heathrow.test",
                segmentID: "piccadilly:940GZZLUHNX:940GZZLUHRC",
                stationIndex: 0
            )
        )) {
            try repository.validate(document, against: graph)
        }
    }

    @Test func segmentPathEndpointsMustMeetStationAnchorsInTheirDeclaredDirection() throws {
        let graph = try TubeGraph.bundled()
        let reversedWithoutReversingArtwork = try makeDocument(
            graph: graph,
            pathDirection: .reverse
        )

        #expect(throws: BeckMapRepositoryError.validationFailed(
            .segmentPathEndpointMismatch(
                segmentID: "piccadilly:940GZZLUHNX:940GZZLUHRC",
                endpoint: "start",
                stationID: "940GZZLUHNX",
                expected: BeckMapPoint(x: 80, y: 50),
                actual: BeckMapPoint(x: 20, y: 50)
            )
        )) {
            try repository.validate(reversedWithoutReversingArtwork, against: graph)
        }
    }

    private func makeDocument(
        graph: TubeGraph,
        geometryStatus: BeckMapGeometryStatus = .authored,
        commands: [BeckMapPathCommand] = [
            .move(to: BeckMapPoint(x: 20, y: 50)),
            .cubic(
                control1: BeckMapPoint(x: 35, y: 50),
                control2: BeckMapPoint(x: 65, y: 50),
                to: BeckMapPoint(x: 80, y: 50)
            ),
        ],
        duplicatePath: Bool = false,
        segmentID: String = "piccadilly:940GZZLUHNX:940GZZLUHRC",
        segmentPathID: String = "heathrow.path",
        pathDirection: BeckMapPathDirection = .forward,
        fromStationID: String = "940GZZLUHRC",
        toStationID: String = "940GZZLUHNX",
        routeStationIDs: [String]? = nil
    ) throws -> BeckMapDocument {
        let path = BeckMapPathRecord(id: "heathrow.path", commands: commands)
        let stationIDs = Set([fromStationID, toStationID] + (routeStationIDs ?? []))
        let markers = try stationIDs.sorted().map { stationID -> BeckMapStationMarkerRecord in
            let station = try #require(graph.stationsByID[stationID])
            let centre = stationID == fromStationID
                ? BeckMapPoint(x: 20, y: 50)
                : BeckMapPoint(x: 80, y: 50)
            return BeckMapStationMarkerRecord(
                stationID: stationID,
                name: station.name,
                lineIDs: [.piccadilly],
                anchor: centre,
                hitRadius: 12,
                primitives: [
                    .circle(BeckMapCirclePrimitive(centre: centre, radius: 4, outlineWidth: 1.5)),
                ]
            )
        }
        let routeStations = routeStationIDs ?? [fromStationID, toStationID]

        return BeckMapDocument(
            schemaVersion: .current,
            identifier: "tube-track-uk.beck.test",
            geometryStatus: geometryStatus,
            source: BeckMapSourceRecord(
                graphSchemaVersion: graph.schemaVersion,
                graphGeneratedAt: graph.generatedAt,
                note: "Test fixture"
            ),
            artworkSize: BeckMapSize(width: 100, height: 100),
            styles: BeckMapStyleRecord(
                routeStrokeWidth: 2,
                affectedOuterStrokeWidth: 8,
                affectedKnockoutStrokeWidth: 6,
                affectedRouteStrokeWidth: 4,
                primaryLabelFontSize: 10,
                secondaryLabelFontSize: 8,
                labelPadding: 2
            ),
            debugReference: BeckMapDebugReferenceRecord(
                resourceName: "test-reference",
                resourceExtension: "png",
                geometryOpacity: 0.4
            ),
            paths: duplicatePath ? [path, path] : [path],
            segments: [
                BeckMapSegmentRecord(
                    id: segmentID,
                    lineID: .piccadilly,
                    fromStationID: fromStationID,
                    toStationID: toStationID,
                    pathID: segmentPathID,
                    pathDirection: pathDirection,
                    translation: .zero
                ),
            ],
            stationMarkers: markers,
            labels: [],
            routes: [
                BeckMapRouteRecord(
                    id: "piccadilly.heathrow.test",
                    lineID: .piccadilly,
                    stationIDs: routeStations,
                    segmentIDs: [segmentID]
                ),
            ]
        )
    }
}
