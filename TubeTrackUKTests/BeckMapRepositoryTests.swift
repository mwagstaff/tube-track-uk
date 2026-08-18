import Foundation
import Testing
@testable import TubeTrackUK

struct BeckMapRepositoryTests {
    private let repository = BeckMapRepository()

    @Test func publishedRegionsAreLimitedToTraceVerifiedArtwork() {
        #expect(Set(BeckMapRegion.allCases.map(\.rawValue)) == [
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
