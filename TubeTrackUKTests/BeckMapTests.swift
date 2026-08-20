import Foundation
import Testing
@testable import TubeTrackUK

struct BeckMapTests {
    @Test func parallelRouteStrokeWidthsMatchOfficialArtworkProportions() {
        let styles = BeckMapStyleRecord(
            routeStrokeWidth: 9,
            affectedOuterStrokeWidth: 19,
            affectedKnockoutStrokeWidth: 15,
            affectedRouteStrokeWidth: 10,
            primaryLabelFontSize: 18,
            secondaryLabelFontSize: 16,
            labelPadding: 2
        )

        #expect(styles.parallelRouteOuterStrokeWidth == 9)
        #expect(styles.parallelRouteInnerStrokeWidth == 3)
    }

    @Test func artworkPrimitivesUseStableTaggedJSON() throws {
        let commands: [BeckMapPathCommand] = [
            .move(to: .init(x: 10, y: 20)),
            .cubic(
                control1: .init(x: 15, y: 20),
                control2: .init(x: 20, y: 25),
                to: .init(x: 20, y: 30)
            ),
            .close,
        ]
        let primitives: [BeckMapStationMarkerPrimitive] = [
            .circle(.init(centre: .init(x: 20, y: 30), radius: 5, outlineWidth: 1.5)),
            .tick(.init(
                lineID: .circle,
                start: .init(x: 18, y: 25),
                end: .init(x: 22, y: 35),
                width: 1.5
            )),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let commandsData = try encoder.encode(commands)
        let primitivesData = try encoder.encode(primitives)
        let commandsJSON = try #require(String(data: commandsData, encoding: .utf8))
        let primitivesJSON = try #require(String(data: primitivesData, encoding: .utf8))

        #expect(commandsJSON.contains("\"op\":\"move\""))
        #expect(commandsJSON.contains("\"op\":\"cubic\""))
        #expect(commandsJSON.contains("\"op\":\"close\""))
        #expect(primitivesJSON.contains("\"kind\":\"circle\""))
        #expect(primitivesJSON.contains("\"kind\":\"tick\""))
        #expect(try JSONDecoder().decode([BeckMapPathCommand].self, from: commandsData) == commands)
        #expect(try JSONDecoder().decode([BeckMapStationMarkerPrimitive].self, from: primitivesData) == primitives)
    }

    @Test func routeResolverRequiresAnExplicitChoiceForDifferentBranchPaths() throws {
        let routeA = BeckMapRouteRecord(
            id: "test.route.a",
            lineID: .northern,
            stationIDs: ["a", "b", "d"],
            segmentIDs: ["a-b", "b-d"]
        )
        let routeB = BeckMapRouteRecord(
            id: "test.route.b",
            lineID: .northern,
            stationIDs: ["a", "c", "d"],
            segmentIDs: ["a-c", "c-d"]
        )
        let document = BeckMapDocument(
            schemaVersion: .current,
            identifier: "test",
            geometryStatus: .authored,
            source: BeckMapSourceRecord(graphSchemaVersion: 1, graphGeneratedAt: "test", note: "test"),
            artworkSize: BeckMapSize(width: 1, height: 1),
            styles: BeckMapStyleRecord(
                routeStrokeWidth: 1,
                affectedOuterStrokeWidth: 4,
                affectedKnockoutStrokeWidth: 3,
                affectedRouteStrokeWidth: 2,
                primaryLabelFontSize: 1,
                secondaryLabelFontSize: 1,
                labelPadding: 1
            ),
            debugReference: BeckMapDebugReferenceRecord(
                resourceName: "test-reference",
                resourceExtension: "png",
                geometryOpacity: 0.4
            ),
            paths: [],
            segments: [],
            stationMarkers: [],
            labels: [],
            routes: [routeA, routeB]
        )
        let resolver = BeckMapRouteResolver(document: document)

        #expect(throws: BeckMapRouteResolutionError.ambiguousRoute(
            lineID: .northern,
            fromStationID: "a",
            toStationID: "d"
        )) {
            try resolver.segmentIDs(on: .northern, from: "a", to: "d")
        }
        #expect(try resolver.segmentIDs(on: .northern, from: "a", to: "d", routeID: routeA.id) == ["a-b", "b-d"])
    }

    @Test func authoredHeathrowLoopIsClosedAndIndependentlyAddressable() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(graph: graph)
        let resolver = BeckMapRouteResolver(document: document)
        let loopRouteID = "piccadilly.heathrow-terminal-4-loop-east.v1"
        let directRouteID = "piccadilly.heathrow-terminal-5-east.v1"
        let terminal5Path = try #require(document.paths.first {
            $0.id == "beck.v1.path.piccadilly.hr5-hrc"
        })
        let terminal4Path = try #require(document.paths.first {
            $0.id == "beck.v1.path.piccadilly.hr4-hrc"
        })

        #expect(Set(document.labels.map(\.stationID)) == Set(document.stationMarkers.map(\.stationID)))
        #expect(Array(terminal5Path.commands.suffix(2)) == Array(terminal4Path.commands.suffix(2)))
        #expect(throws: BeckMapRouteResolutionError.ambiguousRoute(
            lineID: .piccadilly,
            fromStationID: "940GZZLUHNX",
            toStationID: "940GZZLUHRC"
        )) {
            try resolver.segmentIDs(
                on: .piccadilly,
                from: "940GZZLUHNX",
                to: "940GZZLUHRC"
            )
        }
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUHNX",
            to: "940GZZLUHRC",
            routeID: loopRouteID
        ) == [
            "piccadilly:940GZZLUHNX:940GZZLUHR4",
            "piccadilly:940GZZLUHR4:940GZZLUHRC",
        ])
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUHNX",
            to: "940GZZLUHRC",
            routeID: directRouteID
        ) == ["piccadilly:940GZZLUHNX:940GZZLUHRC"])
    }

    @Test func centralSharedCorridorRemainsIndependentlyAddressableByLine() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .centralBackbone, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)
        let bakerStreet = "940GZZLUBST"
        let kingsCross = "940GZZLUKSX"

        let circleSegments = try resolver.segmentIDs(
            on: .circle,
            from: bakerStreet,
            to: kingsCross
        )
        let hammersmithSegments = try resolver.segmentIDs(
            on: .hammersmithCity,
            from: bakerStreet,
            to: kingsCross
        )
        let metropolitanSegments = try resolver.segmentIDs(
            on: .metropolitan,
            from: bakerStreet,
            to: kingsCross
        )

        #expect(circleSegments.count == 3)
        #expect(hammersmithSegments.count == 3)
        #expect(metropolitanSegments.count == 3)
        #expect(Set(circleSegments).isDisjoint(with: hammersmithSegments))
        #expect(Set(circleSegments).isDisjoint(with: metropolitanSegments))
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUBNK",
            to: "940GZZLULNB"
        ) == ["northern:940GZZLUBNK:940GZZLULNB"])
    }

    @Test func westConnectorRangesRemainIndependentlyAddressableByLine() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .westConnector, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        let piccadillyRange = try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUHWT",
            to: "940GZZLUGPK"
        )
        let districtRange = try resolver.segmentIDs(
            on: .district,
            from: "940GZZLUACT",
            to: "940GZZLUSKS"
        )
        let circleRange = try resolver.segmentIDs(
            on: .circle,
            from: "940GZZLUGTR",
            to: "940GZZLUSKS"
        )

        #expect(piccadillyRange.count == 16)
        #expect(districtRange.count == 10)
        #expect(circleRange == ["circle:940GZZLUGTR:940GZZLUSKS"])
        #expect(Set(piccadillyRange).isDisjoint(with: districtRange))
        #expect(Set(piccadillyRange).isDisjoint(with: circleRange))
        #expect(Set(districtRange).isDisjoint(with: circleRange))
    }

    @Test func centralCoreJoinRangesUseTheAuthoredTfLSegments() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .centralCoreJoin, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .jubilee,
            from: "940GZZLUWSM",
            to: "940GZZLULNB"
        ) == [
            "jubilee:940GZZLUWLO:940GZZLUWSM",
            "jubilee:940GZZLUSWK:940GZZLUWLO",
            "jubilee:940GZZLULNB:940GZZLUSWK",
        ])
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUGPK",
            to: "940GZZLUKSX"
        ).count == 6)
        #expect(try resolver.segmentIDs(
            on: .circle,
            from: "940GZZLUSKS",
            to: "940GZZLUCST"
        ).count == 9)
    }

    @Test func eastConnectorRangesUseTheAuthoredTfLSegments() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .eastConnector, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUHBN",
            to: "940GZZLUSTD"
        ).count == 7)
        #expect(try resolver.segmentIDs(
            on: .district,
            from: "940GZZLUCST",
            to: "940GZZLUMED"
        ).count == 6)
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUKSX",
            to: "940GZZLULNB"
        ).count == 5)
        #expect(try resolver.segmentIDs(
            on: .jubilee,
            from: "940GZZLULNB",
            to: "940GZZLUNGW"
        ).count == 4)
    }

    @Test func northConnectorRangesPreserveEveryAuthoredBranch() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .northConnector, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUEGW",
            to: "940GZZLUCTN",
            routeID: "northern.edgware.north-connector.v1"
        ).count == 9)
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUHBT",
            to: "940GZZLUEUS",
            routeID: "northern.high-barnet.north-connector.v1"
        ).count == 12)
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUCTN",
            to: "940GZZLUKSX",
            routeID: "northern.bank-join.north-connector.v1"
        ).count == 2)
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUKSX",
            to: "940GZZLUCKS"
        ).count == 12)
        #expect(try resolver.segmentIDs(
            on: .victoria,
            from: "940GZZLUEUS",
            to: "940GZZLUWWL"
        ).count == 7)
    }

    @Test func southConnectorRangesPreserveEveryAuthoredBranch() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .southConnector, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUWLO",
            to: "940GZZLUMDN",
            routeID: "northern.charing-cross.south-connector.v1"
        ).count == 12)
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZLUKNG",
            to: "940GZZLULNB",
            routeID: "northern.bank.south-connector.v1"
        ).count == 3)
        #expect(try resolver.segmentIDs(
            on: .northern,
            from: "940GZZBPSUST",
            to: "940GZZLUKNG",
            routeID: "northern.battersea.south-connector.v1"
        ).count == 2)
        #expect(try resolver.segmentIDs(
            on: .victoria,
            from: "940GZZLUBXN",
            to: "940GZZLUVIC"
        ).count == 4)
        #expect(try resolver.segmentIDs(
            on: .bakerloo,
            from: "940GZZLUEAC",
            to: "940GZZLUWLO"
        ).count == 2)
    }

    @Test func northwestConnectorRangesPreserveEveryAuthoredBranch() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .northwestConnector, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .bakerloo,
            from: "940GZZLUBST",
            to: "940GZZLUHAW"
        ).count == 16)
        #expect(try resolver.segmentIDs(
            on: .jubilee,
            from: "940GZZLUSTM",
            to: "940GZZLUBST"
        ).count == 13)
        #expect(try resolver.segmentIDs(
            on: .metropolitan,
            from: "940GZZLUUXB",
            to: "940GZZLUBST",
            routeID: "metropolitan.uxbridge.northwest-connector.v1"
        ).count == 13)
        #expect(try resolver.segmentIDs(
            on: .metropolitan,
            from: "940GZZLUAMS",
            to: "940GZZLUBST",
            routeID: "metropolitan.amersham.northwest-connector.v1"
        ).count == 15)
        #expect(try resolver.segmentIDs(
            on: .metropolitan,
            from: "940GZZLUCSM",
            to: "940GZZLUBST",
            routeID: "metropolitan.chesham.northwest-connector.v1"
        ).count == 14)
        #expect(try resolver.segmentIDs(
            on: .metropolitan,
            from: "940GZZLUWAF",
            to: "940GZZLUBST",
            routeID: "metropolitan.watford.northwest-connector.v1"
        ).count == 12)
    }

    @Test func westernFanRangesPreserveEveryAuthoredBranch() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .westernFan, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUWRP",
            to: "940GZZLUOXC",
            routeID: "central.west-ruislip.western-fan.v1"
        ).count == 17)
        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUEBY",
            to: "940GZZLUOXC",
            routeID: "central.ealing.western-fan.v1"
        ).count == 12)
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUUXB",
            to: "940GZZLUACT"
        ).count == 14)
        #expect(try resolver.segmentIDs(
            on: .piccadilly,
            from: "940GZZLUACT",
            to: "940GZZLUGPK",
            routeID: "piccadilly.trunk.western-fan.v1"
        ).count == 9)
        #expect(try resolver.segmentIDs(
            on: .district,
            from: "940GZZLURMD",
            to: "940GZZLUEMB",
            routeID: "district.richmond.western-fan.v1"
        ).count == 16)
        #expect(try resolver.segmentIDs(
            on: .district,
            from: "940GZZLUEBY",
            to: "940GZZLUEMB",
            routeID: "district.ealing.western-fan.v1"
        ).count == 17)
        #expect(try resolver.segmentIDs(
            on: .district,
            from: "940GZZLUECT",
            to: "940GZZLUWIM",
            routeID: "district.wimbledon.western-fan.v1"
        ).count == 8)
        #expect(try resolver.segmentIDs(
            on: .circle,
            from: "940GZZLUHSC",
            to: "940GZZLUPAH",
            routeID: "circle.western.western-fan.v1"
        ).count == 8)
        #expect(try resolver.segmentIDs(
            on: .circle,
            from: "940GZZLUGTR",
            to: "940GZZLUERC",
            routeID: "circle.edgware.western-fan.v1"
        ).count == 5)
        #expect(try resolver.segmentIDs(
            on: .circle,
            from: "940GZZLUGTR",
            to: "940GZZLUEMB",
            routeID: "circle.southern-trunk.western-fan.v1"
        ).count == 6)
    }

    @Test func easternFanRangesPreserveTheEppingAndHainaultBranches() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .easternFan, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUSTD",
            to: "940GZZLUEPG",
            routeID: "central.epping.eastern-fan.v1"
        ).count == 10)
        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUSTD",
            to: "940GZZLUHLT",
            routeID: "central.hainault-via-newbury-park.eastern-fan.v1"
        ).count == 9)
        #expect(try resolver.segmentIDs(
            on: .central,
            from: "940GZZLUSTD",
            to: "940GZZLUHLT",
            routeID: "central.hainault-via-woodford.eastern-fan.v1"
        ).count == 9)
        #expect(try resolver.segmentIDs(
            on: .district,
            from: "940GZZLUMED",
            to: "940GZZLUUPM"
        ).count == 15)
        #expect(try resolver.segmentIDs(
            on: .hammersmithCity,
            from: "940GZZLUMED",
            to: "940GZZLUBKG"
        ).count == 7)
        #expect(try resolver.segmentIDs(
            on: .jubilee,
            from: "940GZZLUNGW",
            to: "940GZZLUSTD"
        ).count == 3)
    }

    @Test func centralCompletionRangesCloseTheLastThreeLineGaps() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .centralCompletion, graph: graph)
        let resolver = BeckMapRouteResolver(document: document)

        #expect(try resolver.segmentIDs(
            on: .bakerloo,
            from: "940GZZLUBST",
            to: "940GZZLUOXC"
        ).count == 2)
        #expect(try resolver.segmentIDs(
            on: .jubilee,
            from: "940GZZLUBST",
            to: "940GZZLUGPK"
        ).count == 2)
        #expect(try resolver.segmentIDs(
            on: .victoria,
            from: "940GZZLUVIC",
            to: "940GZZLUGPK"
        ).count == 1)
    }

    @Test func publishedAuthoredRegionsCoverEveryRailGraphSegment() throws {
        let graph = try TubeGraph.bundled()
        let repository = BeckMapRepository()
        let authoredSegmentIDs = try Set(BeckMapRegion.allCases.flatMap { region in
            try repository.load(region: region, graph: graph).segments.map(\.id)
        })

        #expect(Set(graph.segments.map(\.id)).isSubset(of: authoredSegmentIDs))
    }

    @Test func authoredHeathrowTracePreservesTheReferenceDiagonalAndHiddenJunctions() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(graph: graph)
        let markers = Dictionary(uniqueKeysWithValues: document.stationMarkers.map { ($0.stationID, $0) })
        let diagonalStationIDs = [
            "940GZZLUHRC",
            "940GZZLUHNX",
            "940GZZLUHWT",
        ]

        for stationID in diagonalStationIDs {
            let anchor = try #require(markers[stationID]?.anchor)
            #expect(abs(anchor.x + anchor.y - 1_065) < 0.001)
        }

        let terminal4Entry = try #require(document.paths.first {
            $0.id == "beck.v1.path.piccadilly.hnx-hr4"
        })
        #expect(Array(terminal4Entry.commands.prefix(2)) == [
            .move(to: BeckMapPoint(x: 740, y: 325)),
            .line(to: BeckMapPoint(x: 710, y: 355)),
        ])

        let terminal5Path = try #require(document.paths.first {
            $0.id == "beck.v1.path.piccadilly.hr5-hrc"
        })
        let terminal4Return = try #require(document.paths.first {
            $0.id == "beck.v1.path.piccadilly.hr4-hrc"
        })
        let sharedDiagonal: [BeckMapPathCommand] = [
            .line(to: BeckMapPoint(x: 338, y: 727)),
            .line(to: BeckMapPoint(x: 610, y: 455)),
        ]
        #expect(Array(terminal5Path.commands.suffix(2)) == sharedDiagonal)
        #expect(Array(terminal4Return.commands.suffix(2)) == sharedDiagonal)
        #expect(document.styles.routeStrokeWidth == 28)
        #expect(document.debugReference.geometryOpacity == 0.4)
    }
}
