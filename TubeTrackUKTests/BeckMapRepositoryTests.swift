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

    @Test func bundledFullUndergroundMapIsCompleteAndStrictlyValidated() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)

        #expect(document.identifier == "tube-track-uk.beck.full-underground.v1")
        #expect(document.artworkSize == BeckMapSize(width: 4_764, height: 3_632))
        #expect(document.paths.count == 379)
        #expect(document.segments.count == 379)
        #expect(document.stationMarkers.count == graph.stations.count)
        #expect(document.labels.count == graph.stations.count)
        #expect(Set(document.segments.map(\.lineID)) == Set(TubeLineID.allCases))
        #expect(Set(graph.segments.map(\.id)).isSubset(of: Set(document.segments.map(\.id))))
        #expect(document.segments.contains {
            $0.id == BeckMapRepository.supplementalHeathrowSegmentID
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
        #expect(circleCount(finchleyCentral) == 1)
        #expect(connectorCount(finchleyCentral) == 0)

        let camdenTown = try marker("940GZZLUCTN")
        #expect(circleCount(camdenTown) == 1)
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
        #expect(circleCount(bondStreet) == 2)
        #expect(connectorCount(bondStreet) == 1)
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
        #expect(circleCount(canaryWharf) == 0)
        #expect(tickCount(canaryWharf) == 1)
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
        ] {
            let ordinarySharedMarker = try marker(stationID)
            #expect(circleCount(ordinarySharedMarker) == 0)
            #expect(connectorCount(ordinarySharedMarker) == 0)
            #expect(tickCount(ordinarySharedMarker) == expectedTicks)
        }

        for stationID in ["940GZZLUGTR", "940GZZLUSKS"] {
            let subSurfacePiccadillyInterchange = try marker(stationID)
            #expect(circleCount(subSurfacePiccadillyInterchange) == 2)
            #expect(connectorCount(subSurfacePiccadillyInterchange) == 1)
        }

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
        #expect(circleCount(bank) == 3)
        #expect(connectorCount(bank) == 2)

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
        #expect(mileEnd.anchor.x - stepneyGreen.anchor.x > 70)

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

        for stationID in ["940GZZLUHR5", "940GZZLUHRC", "940GZZLUHNX", "940GZZLUHR4"] {
            let heathrowMarker = try marker(stationID)
            #expect(circleCount(heathrowMarker) == 1)
            #expect(connectorCount(heathrowMarker) == 0)
        }
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

    @Test func labelPlacementCandidatesPreserveAuthoredDirectionAndBoundDistance() {
        let station = CGPoint(x: 200, y: 300)
        let artworkOffset = CGVector(dx: -110, dy: 4)
        let candidates = BeckMapLabelPlacementResolver.candidates(
            stationScreenPosition: station,
            artworkOffset: artworkOffset
        )

        let preferred = candidates.first
        #expect(preferred?.alignment == .trailing)
        #expect(abs(hypot(
            (preferred?.position.x ?? 0) - station.x,
            (preferred?.position.y ?? 0) - station.y
        ) - BeckMapLabelPlacementResolver.preferredTether) < 0.001)
        #expect(candidates.allSatisfy {
            hypot($0.position.x - station.x, $0.position.y - station.y)
                <= BeckMapLabelPlacementResolver.maximumTether + 0.001
        })
    }

    @Test func goodgeStreetAndTottenhamCourtRoadLabelsStayWithTheirOwnStations() throws {
        let graph = try TubeGraph.bundled()
        let document = try repository.load(region: .fullUnderground, graph: graph)
        func screenDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        }

        let goodgeID = "940GZZLUGDG"
        let tottenhamCourtRoadID = "940GZZLUTCR"
        let goodgeMarker = try #require(document.stationMarkers.first { $0.stationID == goodgeID })
        let tottenhamCourtRoadMarker = try #require(document.stationMarkers.first {
            $0.stationID == tottenhamCourtRoadID
        })
        let goodgeLabel = try #require(document.labels.first { $0.stationID == goodgeID })
        let tottenhamCourtRoadLabel = try #require(document.labels.first {
            $0.stationID == tottenhamCourtRoadID
        })

        for scale in [CGFloat(1), 2, 4] {
            let goodgeStation = CGPoint(x: goodgeMarker.anchor.x * scale, y: goodgeMarker.anchor.y * scale)
            let tottenhamCourtRoadStation = CGPoint(
                x: tottenhamCourtRoadMarker.anchor.x * scale,
                y: tottenhamCourtRoadMarker.anchor.y * scale
            )
            let goodgePosition = try #require(BeckMapLabelPlacementResolver.candidates(
                stationScreenPosition: goodgeStation,
                artworkOffset: CGVector(
                    dx: goodgeLabel.position.x - goodgeMarker.anchor.x,
                    dy: goodgeLabel.position.y - goodgeMarker.anchor.y
                )
            ).first).position
            let tottenhamCourtRoadPosition = try #require(BeckMapLabelPlacementResolver.candidates(
                stationScreenPosition: tottenhamCourtRoadStation,
                artworkOffset: CGVector(
                    dx: tottenhamCourtRoadLabel.position.x - tottenhamCourtRoadMarker.anchor.x,
                    dy: tottenhamCourtRoadLabel.position.y - tottenhamCourtRoadMarker.anchor.y
                )
            ).first).position

            #expect(screenDistance(goodgePosition, goodgeStation)
                <= BeckMapLabelPlacementResolver.preferredTether + 0.001)
            #expect(screenDistance(tottenhamCourtRoadPosition, tottenhamCourtRoadStation)
                <= BeckMapLabelPlacementResolver.preferredTether + 0.001)
            #expect(screenDistance(goodgePosition, goodgeStation)
                < screenDistance(goodgePosition, tottenhamCourtRoadStation))
            #expect(screenDistance(tottenhamCourtRoadPosition, tottenhamCourtRoadStation)
                < screenDistance(tottenhamCourtRoadPosition, goodgeStation))
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
                start: CGPoint(x: 0, y: 100),
                end: CGPoint(x: 200, y: 100),
                clearance: 8
            ),
            BeckMapLineBlocker(
                start: CGPoint(x: 100, y: 0),
                end: CGPoint(x: 100, y: 200),
                clearance: 8
            ),
        ]
        let candidates = BeckMapLabelPlacementResolver.candidates(
            stationScreenPosition: station,
            artworkOffset: CGVector(dx: 0, dy: -20)
        )
        let placement = try #require(candidates.first { candidate in
            let size = CGSize(width: 82, height: 26)
            let originX: CGFloat
            switch candidate.alignment {
            case .leading: originX = candidate.position.x
            case .centre: originX = candidate.position.x - size.width / 2
            case .trailing: originX = candidate.position.x - size.width
            }
            let frame = CGRect(
                x: originX,
                y: candidate.position.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            return BeckMapLabelCollisionResolver.accepts(
                frame,
                markerBlockers: [marker],
                lineBlockers: routes,
                occupied: []
            )
        })

        #expect(hypot(placement.position.x - station.x, placement.position.y - station.y)
            >= BeckMapLabelPlacementResolver.preferredTether)
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
