import Testing
@testable import TubeTrackUK

struct LionessArtworkTests {
    @Test func sharedBakerlooStationsUseLineMarkers() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let markersByID = Dictionary(uniqueKeysWithValues: document.stationMarkers.map {
            ($0.stationID, $0)
        })
        let sharedStationIDs = [
            "910GHROW",
            "910GKTON",
            "910GSKENTON",
            "910GNWEMBLY",
            "910GWMBY",
            "910GSTNBGPK",
            "910GHARLSDN",
            "910GKENSLG",
        ]

        for stationID in sharedStationIDs {
            let marker = try #require(markersByID[stationID])
            #expect(marker.primitives.count == 1)
            #expect(marker.primitives.allSatisfy { primitive in
                guard case let .tick(tick) = primitive else { return false }
                return tick.lineID == .lioness
            })
        }
    }

    @Test func queensParkToSouthHampsteadFollowsOfficialSteppedTrace() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let marker = try #require(document.stationMarkers.first {
            $0.stationID == "910GKLBRNHR"
        })
        let westernPath = try #require(document.paths.first {
            $0.id == "beck.v1.path.lioness.euston-watford.official.v1.2"
        })
        let easternPath = try #require(document.paths.first {
            $0.id == "beck.v1.path.lioness.euston-watford.official.v1.1"
        })

        #expect(marker.anchor == BeckMapPoint(x: 1349, y: 1305))
        #expect(westernPath.commands == [
            .move(to: BeckMapPoint(x: 1349, y: 1305)),
            .line(to: BeckMapPoint(x: 1228, y: 1305)),
            .cubic(
                control1: BeckMapPoint(x: 1218, y: 1305),
                control2: BeckMapPoint(x: 1213.985, y: 1304.111),
                to: BeckMapPoint(x: 1207.985, y: 1298.111)
            ),
            .line(to: BeckMapPoint(x: 1185.985, y: 1276.111)),
        ])
        #expect(easternPath.commands == [
            .move(to: BeckMapPoint(x: 1737.692, y: 1254.708)),
            .line(to: BeckMapPoint(x: 1618, y: 1254.708)),
            .cubic(
                control1: BeckMapPoint(x: 1600, y: 1254.708),
                control2: BeckMapPoint(x: 1578, y: 1305),
                to: BeckMapPoint(x: 1562, y: 1305)
            ),
            .line(to: BeckMapPoint(x: 1349, y: 1305)),
        ])
    }

    @Test func queensParkKeepsLionessOffsetFromBakerloo() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let segmentsByID = Dictionary(uniqueKeysWithValues: document.segments.map {
            ($0.id, $0)
        })
        let lionessWest = try #require(segmentsByID["lioness:910GKLBRNHR:910GQPRK"])
        let lionessNorth = try #require(segmentsByID["lioness:910GKENSLG:910GQPRK"])
        let bakerlooSouth = try #require(segmentsByID["bakerloo:940GZZLUKPK:940GZZLUQPS"])
        let bakerlooNorth = try #require(segmentsByID["bakerloo:940GZZLUKSL:940GZZLUQPS"])

        let lionessPort = BeckMapPoint(x: 1185.985, y: 1276.111)
        let bakerlooPort = BeckMapPoint(x: 1172.907, y: 1276.111)
        #expect(lionessWest.toPort == lionessPort)
        #expect(lionessNorth.fromPort == lionessPort)
        #expect(bakerlooSouth.toPort == bakerlooPort)
        #expect(bakerlooNorth.fromPort == bakerlooPort)
        #expect(abs(lionessPort.x - bakerlooPort.x - 13.078) < 0.001)
    }

    @Test func willesdenJunctionHasNoConnectorAndUsesTheOfficialMildmayKink() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let marker = try #require(document.stationMarkers.first {
            $0.stationID == "910GWLSDJHL"
        })
        let eastPath = try #require(document.paths.first {
            $0.id == "beck.v1.path.mildmay.stratford-clapham.official.v1.16"
        })
        let claphamPath = try #require(document.paths.first {
            $0.id == "beck.v1.path.mildmay.stratford-clapham.official.v1.17"
        })
        let richmondPath = try #require(document.paths.first {
            $0.id == "beck.v1.path.mildmay.willesden-richmond.official.v1.0"
        })
        let stationPort = BeckMapPoint(x: 1155.547, y: 1175.222)
        let westKink = BeckMapPoint(x: 1113.547, y: 1175.222)
        let curve = BeckMapPathCommand.cubic(
            control1: BeckMapPoint(x: 1095, y: 1175.222),
            control2: BeckMapPoint(x: 1076, y: 1176),
            to: BeckMapPoint(x: 1067.532, y: 1183.125)
        )

        #expect(marker.primitives.count == 1)
        #expect(marker.primitives.allSatisfy { primitive in
            if case .circle = primitive { return true }
            return false
        })
        #expect(eastPath.commands == [
            .move(to: BeckMapPoint(x: 1232.263, y: 1174.922)),
            .line(to: stationPort),
        ])
        #expect(Array(claphamPath.commands.prefix(3)) == [
            .move(to: stationPort),
            .line(to: westKink),
            curve,
        ])
        #expect(Array(richmondPath.commands.prefix(3)) == [
            .move(to: stationPort),
            .line(to: westKink),
            curve,
        ])
    }
}
