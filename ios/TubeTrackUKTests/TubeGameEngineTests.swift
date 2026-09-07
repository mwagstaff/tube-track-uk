import CoreGraphics
import Foundation
import Testing
@testable import TubeTrackUK

@Suite("Track Attack engine")
struct TubeGameEngineTests {
#if DEBUG
    @Test func debugPlaybackCanRunAtTenPercentSpeedOrFreezeCompletely() {
        #expect(TubeGameDebugPlayback.scaledDelta(
            1,
            timeScale: TubeGameDebugPlayback.slowMotionScale,
            isPaused: false
        ) == 0.1)
        #expect(TubeGameDebugPlayback.scaledDelta(
            1,
            timeScale: 1,
            isPaused: true
        ) == 0)
        #expect(TubeGameDebugPlayback.scaledDelta(
            .infinity,
            timeScale: 1,
            isPaused: false
        ) == 0)
    }
#endif

    @Test @MainActor func collisionRetainsTrainLineAndRestartClearsIt() throws {
        var configuration = TubeGameConfiguration.standard
        configuration.countdownDuration = 0
        configuration.collisionDistance = 100_000
        let engine = try TubeGameEngine(network: makeNetwork(), configuration: configuration, seed: 7)
        let expectedLine = try #require(engine.snapshot.trains.first?.lineID)
        engine.start()
        engine.tick(deltaTime: 0.02)
        #expect(engine.snapshot.phase == .ended(.collision))
        #expect(engine.collisionLineID == expectedLine)
        engine.restart(seed: 8)
        #expect(engine.collisionLineID == nil)
    }

    @Test func fullNetworkUsesPhysicalHubIdentityAcrossAllTwentyLines() throws {
        let network = try makeNetwork()

        #expect(network.nodes.count == 509)
        #expect(network.hubs.count == 457)
        #expect(network.collectibleHubCount == 457)
        #expect(Set(network.edges.compactMap(\.kind.lineID)) == Set(TubeLineID.allCases))
        #expect(Set(network.lineHubIDs.keys) == Set(TubeLineID.allCases))
        #expect(network.lineHubIDs.values.allSatisfy { !$0.isEmpty })
        let ealingBroadwayHubID = try #require(network.node(stationID: "940GZZLUEBY")?.hubID)
        let oxfordCircusHubID = try #require(network.node(stationID: "940GZZLUOXC")?.hubID)
        #expect(network.terminusHubIDs.contains(ealingBroadwayHubID))
        #expect(!network.terminusHubIDs.contains(oxfordCircusHubID))
        #expect(network.edges.contains { $0.kind.isTransfer })

        let groupedNodeCount = network.hubs.reduce(0) { $0 + $1.stationIDs.count }
        #expect(groupedNodeCount == network.nodes.count)
        #expect(network.hubs.contains { $0.stationIDs.count > 1 && $0.lineIDs.count > 1 })
    }

    @Test func completedLinesUseConsumedPhysicalHubsAndCountEachLineOnce() {
        let configuration = TubeGameConfiguration.standard
        var tracker = TubeGameScoreTracker()
        let lineHubIDs: [TubeLineID: Set<String>] = [
            .central: ["start", "a"],
            .victoria: ["a", "b"],
            .bakerloo: [],
        ]

        tracker.markStartingHubConsumed("start")
        tracker.refreshCompletedLines(lineHubIDs: lineHubIDs)
        #expect(tracker.completedLineIDs.isEmpty)

        _ = tracker.consume(
            hub: hub(id: "a", lines: [.central, .victoria]),
            enteredOn: .central,
            configuration: configuration
        )
        tracker.refreshCompletedLines(lineHubIDs: lineHubIDs)
        #expect(tracker.completedLineIDs == [.central])

        _ = tracker.consume(
            hub: hub(id: "b", lines: [.victoria]),
            enteredOn: .victoria,
            configuration: configuration
        )
        tracker.refreshCompletedLines(lineHubIDs: lineHubIDs)
        tracker.refreshCompletedLines(lineHubIDs: lineHubIDs)
        #expect(tracker.completedLineIDs == [.central, .victoria])
    }

    @Test func scoringRewardsInterchangeSizeAndSmallCappedSameLineStreaks() {
        let configuration = TubeGameConfiguration.standard
        var tracker = TubeGameScoreTracker()
        tracker.markStartingHubConsumed("start")

        let ordinary = hub(id: "ordinary", lines: [.central])
        let largeInterchange = hub(id: "large", lines: [.central, .victoria, .bakerloo])
        let third = hub(id: "third", lines: [.central])
        let fourth = hub(id: "fourth", lines: [.victoria])

        let firstEvent = tracker.consume(
            hub: ordinary,
            enteredOn: .central,
            configuration: configuration
        )
        let secondEvent = tracker.consume(
            hub: largeInterchange,
            enteredOn: .central,
            configuration: configuration
        )
        let thirdEvent = tracker.consume(
            hub: third,
            enteredOn: .central,
            configuration: configuration
        )

        #expect(firstEvent?.total == 10)
        #expect(secondEvent?.stationPoints == 20)
        #expect(secondEvent?.streakBonus == 2)
        #expect(thirdEvent?.total == 14)
        #expect(tracker.score == 46)
        #expect(tracker.sameLineStreak == 3)

        let scoreBeforeRevisit = tracker.score
        #expect(tracker.consume(
            hub: ordinary,
            enteredOn: .victoria,
            configuration: configuration
        ) == nil)
        #expect(tracker.score == scoreBeforeRevisit)
        #expect(tracker.sameLineStreak == 3)

        let lineSwitch = tracker.consume(
            hub: fourth,
            enteredOn: .victoria,
            configuration: configuration
        )
        #expect(lineSwitch?.streakBonus == 0)
        #expect(tracker.sameLineStreak == 1)

        for index in 0 ..< 7 {
            _ = tracker.consume(
                hub: hub(id: "cap-\(index)", lines: [.victoria]),
                enteredOn: .victoria,
                configuration: configuration
            )
        }
        #expect(tracker.lastEvent?.streakBonus == 10)
    }

    @Test func terminusStationsAreCountedOnceWhenConsumed() {
        let configuration = TubeGameConfiguration.standard
        var tracker = TubeGameScoreTracker()
        let terminus = hub(id: "terminus", lines: [.central])
        let ordinary = hub(id: "ordinary", lines: [.central])

        #expect(tracker.consume(
            hub: terminus,
            enteredOn: .central,
            isTerminus: true,
            configuration: configuration
        ) != nil)
        #expect(tracker.terminusStationsReached == 1)

        #expect(tracker.consume(
            hub: terminus,
            enteredOn: .central,
            isTerminus: true,
            configuration: configuration
        ) == nil)
        _ = tracker.consume(
            hub: ordinary,
            enteredOn: .central,
            configuration: configuration
        )
        #expect(tracker.terminusStationsReached == 1)
    }

    @Test func everyRoundelInAPhysicalStationIsConsumedByOneScoreEvent() {
        let configuration = TubeGameConfiguration.standard
        let interchange = TubeGameHub(
            id: "interchange",
            name: "Interchange",
            representativeStationID: "platform-a",
            stationIDs: ["platform-a", "platform-b", "platform-c"],
            lineIDs: [.northern, .victoria],
            point: .zero
        )
        var tracker = TubeGameScoreTracker()

        #expect(tracker.consume(
            hub: interchange,
            enteredOn: .northern,
            configuration: configuration
        ) != nil)
        let scoreAfterFirstRoundel = tracker.score

        #expect(tracker.consume(
            hub: interchange,
            enteredOn: .victoria,
            configuration: configuration
        ) == nil)
        #expect(tracker.consumedHubIDs == ["interchange"])
        #expect(tracker.stationsEaten == 1)
        #expect(tracker.score == scoreAfterFirstRoundel)
    }

    @Test func playerKeepsAuthoredRailGeometryThroughKenningtonWithoutAnchorJumps() throws {
        let network = try makeNetwork()
        let incoming = try #require(network.directedEdge(
            edgeID: "northern:940GZZLUEAC:940GZZLUKNG",
            fromStationID: "940GZZLUEAC"
        ))
        let outgoing = try #require(network.directedEdge(
            edgeID: "northern:940GZZLUKNG:940GZZLUOVL",
            fromStationID: "940GZZLUKNG"
        ))
        let arrival = incoming.playerPoint(atDistance: incoming.playerLength)
        let authoredArrival = try #require(incoming.edge.geometry.points.first)
        let logicalAnchor = try #require(network.node(stationID: "940GZZLUKNG")?.point)

        #expect(arrival == authoredArrival)
        #expect(arrival != logicalAnchor)

        let transition = try #require(network.stationTransition(
            fromStationID: "940GZZLUKNG",
            position: arrival,
            to: outgoing
        ))
        #expect(transition.isTransfer)
        #expect(transition.playerPoint(atDistance: 0) == arrival)
        #expect(transition.playerPoint(atDistance: transition.playerLength)
            == outgoing.playerPoint(atDistance: 0))
    }

    @MainActor
    @Test func playerMotionRemainsContinuousAcrossInterchangeBoundaries() throws {
        let network = try makeNetwork()
        var configuration = quietConfiguration()
        configuration.duration = 8
        configuration.playerSpeed = 240
        configuration.startPolicy = .fixed(stationID: "940GZZLUKNG")
        configuration.initialDirection = .north
        let engine = try TubeGameEngine(
            network: network,
            configuration: configuration,
            seed: 41
        )
        engine.start()

        let step: TimeInterval = 0.01
        let maximumStepDistance = configuration.playerSpeed * CGFloat(step) + 0.001
        var previousPosition = engine.snapshot.player.position
        for _ in 0 ..< 600 {
            engine.tick(deltaTime: step)
            let position = engine.snapshot.player.position
            #expect(hypot(
                position.x - previousPosition.x,
                position.y - previousPosition.y
            ) <= maximumStepDistance)
            if let lineID = engine.snapshot.player.lineID {
                #expect(lineID == .northern)
            }
            previousPosition = position
        }
    }

    @Test func queuedDirectionWinsThenFallbackContinuesStraightAndDeadEndReverses() throws {
        let right = candidate(id: "right", vector: CGVector(dx: 1, dy: 0))
        let up = candidate(id: "up", vector: CGVector(dx: 0, dy: -1))
        let reverse = candidate(
            id: "reverse",
            vector: CGVector(dx: -1, dy: 0),
            isReverse: true
        )

        let queued = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, up, reverse],
            queuedDirection: .north,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true
        ))
        #expect(queued.connection.edgeID == "up")
        #expect(queued.usedQueuedDirection)

        let diagonalWithoutDiagonalExit = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, up, reverse],
            queuedDirection: .northEast,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true
        ))
        #expect(diagonalWithoutDiagonalExit.connection.edgeID == "right")
        #expect(!diagonalWithoutDiagonalExit.usedQueuedDirection)
        #expect(diagonalWithoutDiagonalExit.shouldClearQueuedDirection)

        let straight = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, up, reverse],
            queuedDirection: .south,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true,
            acceptanceDegrees: 20
        ))
        #expect(straight.connection.edgeID == "right")
        #expect(!straight.usedQueuedDirection)
        #expect(straight.shouldClearQueuedDirection)

        let ordinaryStation = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, reverse],
            queuedDirection: .south,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true,
            acceptanceDegrees: 20
        ))
        #expect(ordinaryStation.connection.edgeID == "right")
        #expect(!ordinaryStation.usedQueuedDirection)
        #expect(!ordinaryStation.shouldClearQueuedDirection)

        let matchingForwardAtOrdinaryStation = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, reverse],
            queuedDirection: .east,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true,
            acceptanceDegrees: 20
        ))
        #expect(matchingForwardAtOrdinaryStation.connection.edgeID == "right")
        #expect(!matchingForwardAtOrdinaryStation.usedQueuedDirection)
        #expect(!matchingForwardAtOrdinaryStation.shouldClearQueuedDirection)

        let diagonalIntentAtOrdinaryStation = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, reverse],
            queuedDirection: .northWest,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true
        ))
        #expect(diagonalIntentAtOrdinaryStation.connection.edgeID == "right")
        #expect(!diagonalIntentAtOrdinaryStation.usedQueuedDirection)
        #expect(!diagonalIntentAtOrdinaryStation.shouldClearQueuedDirection)

        let explicitUTurn = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, reverse],
            queuedDirection: .west,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true,
            acceptanceDegrees: 20
        ))
        #expect(explicitUTurn.connection.edgeID == "reverse")
        #expect(explicitUTurn.usedQueuedDirection)
        #expect(explicitUTurn.shouldClearQueuedDirection)

        let deadEnd = try #require(TubeGameJunctionRouter.choose(
            candidates: [reverse],
            queuedDirection: .west,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true
        ))
        #expect(deadEnd.connection.edgeID == "reverse")
        #expect(!deadEnd.usedQueuedDirection)
        #expect(!deadEnd.shouldClearQueuedDirection)

        let northEast = candidate(
            id: "north-east",
            vector: CGVector(dx: 1, dy: -1)
        )
        let northEastOtherLine = candidate(
            id: "north-east-other-line",
            vector: CGVector(dx: 1, dy: -1),
            isCurrentLine: false
        )
        let diagonal = try #require(TubeGameJunctionRouter.choose(
            candidates: [right, up, northEastOtherLine, northEast],
            queuedDirection: .northEast,
            incomingHeading: CGVector(dx: 1, dy: 0),
            hasCurrentLine: true
        ))
        #expect(diagonal.connection.edgeID == "north-east")
        #expect(diagonal.usedQueuedDirection)
        #expect(diagonal.shouldClearQueuedDirection)
    }

    @Test func standardControlsAcceptTheClosestDiagonalExitForACardinalSwipe() throws {
        let northEast = candidate(
            id: "north-east",
            vector: CGVector(dx: 1, dy: -1)
        )
        let east = candidate(
            id: "east",
            vector: CGVector(dx: 1, dy: 0)
        )

        let decision = try #require(TubeGameJunctionRouter.choose(
            candidates: [east, northEast],
            queuedDirection: .north,
            incomingHeading: CGVector(dx: 0, dy: -1),
            hasCurrentLine: true,
            acceptanceDegrees: TubeGameConfiguration.standard.directionAcceptanceDegrees
        ))

        #expect(decision.connection.edgeID == "north-east")
        #expect(decision.usedQueuedDirection)
        #expect(decision.shouldClearQueuedDirection)
    }

    @Test func matchingIntentStaysBufferedAcrossThroughStationThenTurnsAtBranch() throws {
        let northEastThrough = candidate(
            id: "through-forward",
            vector: CGVector(dx: 1, dy: -1)
        )
        let southWestReverse = candidate(
            id: "through-reverse",
            vector: CGVector(dx: -1, dy: 1),
            isReverse: true
        )
        let throughDecision = try #require(TubeGameJunctionRouter.choose(
            candidates: [northEastThrough, southWestReverse],
            queuedDirection: .northEast,
            incomingHeading: CGVector(dx: 1, dy: -1),
            hasCurrentLine: true
        ))
        #expect(throughDecision.connection.edgeID == "through-forward")
        #expect(!throughDecision.usedQueuedDirection)
        #expect(!throughDecision.shouldClearQueuedDirection)

        let eastBranch = candidate(
            id: "branch-east",
            vector: CGVector(dx: 1, dy: 0)
        )
        let northEastBranch = candidate(
            id: "branch-north-east",
            vector: CGVector(dx: 1, dy: -1)
        )
        let branchDecision = try #require(TubeGameJunctionRouter.choose(
            candidates: [eastBranch, northEastBranch, southWestReverse],
            queuedDirection: .northEast,
            incomingHeading: CGVector(dx: 1, dy: -1),
            hasCurrentLine: true
        ))
        #expect(branchDecision.connection.edgeID == "branch-north-east")
        #expect(branchDecision.usedQueuedDirection)
        #expect(branchDecision.shouldClearQueuedDirection)
    }

    @Test func trainQuotasCoverAllLinesAndTotalTwentyNine() throws {
        let network = try makeNetwork()
        let simulation = TubeGameTrainSimulation(
            network: network,
            seed: 123,
            startHubID: "940GZZLUOXC",
            configuration: .standard
        )

        #expect(TubeGameTrainSimulation.trainQuota(forSegmentCount: 0) == 0)
        #expect(TubeGameTrainSimulation.trainQuota(forSegmentCount: 29) == 1)
        #expect(TubeGameTrainSimulation.trainQuota(forSegmentCount: 30) == 2)
        #expect(TubeGameTrainSimulation.trainQuota(forSegmentCount: 60) == 3)
        #expect(TubeGameTrainSimulation.totalTrainQuota(in: network) == 29)
        #expect(simulation.snapshots.count == 29)
        #expect(Set(simulation.snapshots.map(\.lineID)) == Set(TubeLineID.allCases))

        let hopDistances = network.shortestHubHopDistances(from: "940GZZLUOXC")
        for train in simulation.snapshots {
            let edge = try #require(network.edge(id: train.edgeID))
            let fromHub = try #require(network.node(stationID: edge.fromStationID)?.hubID)
            let toHub = try #require(network.node(stationID: edge.toStationID)?.hubID)
            #expect((hopDistances[fromHub] ?? .max) >= 2)
            #expect((hopDistances[toHub] ?? .max) >= 2)
        }
    }

    @Test func seededTrainLayoutsAndMotionAreReproducible() throws {
        let network = try makeNetwork()
        var first = TubeGameTrainSimulation(
            network: network,
            seed: 0xCAFE,
            startHubID: "940GZZLUOXC",
            configuration: .standard
        )
        var second = TubeGameTrainSimulation(
            network: network,
            seed: 0xCAFE,
            startHubID: "940GZZLUOXC",
            configuration: .standard
        )
        let different = TubeGameTrainSimulation(
            network: network,
            seed: 0xBEEF,
            startHubID: "940GZZLUOXC",
            configuration: .standard
        )

        #expect(first.snapshots == second.snapshots)
        #expect(first.snapshots != different.snapshots)
        first.advance(by: 1.25)
        second.advance(by: 1.25)
        #expect(first.snapshots == second.snapshots)
    }

    @MainActor
    @Test func countdownDoesNotConsumeTimeAndRunExpiresAtExactlyConfiguredDuration() throws {
        let network = try makeNetwork()
        var configuration = TubeGameConfiguration.standard
        configuration.duration = 1
        configuration.countdownDuration = 0.5
        configuration.playerSpeed = 0
        configuration.trainSpeed = 0
        configuration.collisionDistance = 0
        let engine = try TubeGameEngine(network: network, configuration: configuration, seed: 42)

        #expect(engine.snapshot.score == 0)
        #expect(engine.snapshot.stationsEaten == 0)
        #expect(engine.snapshot.consumedHubIDs == ["940GZZLUOXC"])
        engine.start()
        engine.tick(deltaTime: 0.5)
        #expect(engine.snapshot.phase == .playing)
        #expect(engine.snapshot.elapsedTime == 0)

        engine.tick(deltaTime: 0.4)
        #expect(engine.snapshot.phase == .playing)
        #expect(abs(engine.snapshot.remainingTime - 0.6) < 0.000_001)
        engine.tick(deltaTime: 0.6)
        #expect(engine.snapshot.phase == .ended(.completed))
        #expect(engine.snapshot.elapsedTime == 1)
        #expect(engine.snapshot.remainingTime == 0)

        engine.tick(deltaTime: 10)
        #expect(engine.snapshot.elapsedTime == 1)
    }

    @MainActor
    @Test func defaultOpeningOffersTimeToReactAcrossSeeds() throws {
        let network = try makeNetwork()
        let reactionWindow: TimeInterval = 5

        for seed in UInt64(0) ..< 12 {
            let engine = try TubeGameEngine(
                network: network,
                configuration: .standard,
                seed: seed
            )
            engine.start()
            engine.tick(deltaTime: TubeGameConfiguration.standard.countdownDuration)
            engine.tick(deltaTime: reactionWindow)

            if case .ended(.collision) = engine.snapshot.phase {
                let player = engine.snapshot.player.position
                let nearestTrain = engine.snapshot.trains.min { lhs, rhs in
                    hypot(lhs.position.x - player.x, lhs.position.y - player.y)
                        < hypot(rhs.position.x - player.x, rhs.position.y - player.y)
                }
                let trainDescription = nearestTrain.map {
                    "\($0.lineID.displayName), distance \(hypot($0.position.x - player.x, $0.position.y - player.y))"
                } ?? "none"
                Issue.record(
                    "Seed \(seed) collided after \(engine.snapshot.elapsedTime)s at \(engine.snapshot.player.stationName); nearest train: \(trainDescription)"
                )
            }
            #expect(engine.snapshot.stationsEaten > 0)
        }
    }

    @MainActor
    @Test func routePreviewSelectsExactCardinalDiagonalAndInvalidFallbackRails() throws {
        let network = try makeNetwork()
        let cardinal = try #require(findStartChoice(
            in: network,
            directions: [.north, .east, .south, .west],
            usedQueuedDirection: true
        ))
        let diagonal = try #require(findStartChoice(
            in: network,
            directions: [.northEast, .southEast, .southWest, .northWest],
            usedQueuedDirection: true
        ))
        let invalid = try #require(findStartChoice(
            in: network,
            directions: TubeGameDirection.allCases,
            usedQueuedDirection: false
        ))

        for choice in [cardinal, diagonal, invalid] {
            var configuration = quietConfiguration()
            configuration.startPolicy = .fixed(
                stationID: choice.hub.representativeStationID
            )
            configuration.initialDirection = choice.direction
            let engine = try TubeGameEngine(
                network: network,
                configuration: configuration,
                seed: 19
            )
            let preview = try #require(engine.snapshot.routePreview)
            let expected = choice.decision.connection

            #expect(preview.direction == choice.direction)
            #expect(preview.edgeID == expected.edgeID)
            #expect(preview.fromStationID == expected.fromStationID)
            #expect(preview.toStationID == expected.toStationID)
            #expect(preview.lineID == expected.lineID)
            #expect(!preview.isCommitted)
        }
        #expect(!invalid.decision.usedQueuedDirection)
        #expect(invalid.decision.shouldClearQueuedDirection)
    }

    @MainActor
    @Test func availableSwipeHintsMatchOnlyDirectionsConsumedByTheNextChoice() throws {
        let network = try makeNetwork()
        let invalid = try #require(findStartChoice(
            in: network,
            directions: TubeGameDirection.allCases,
            usedQueuedDirection: false
        ))
        var configuration = quietConfiguration()
        configuration.startPolicy = .fixed(
            stationID: invalid.hub.representativeStationID
        )
        configuration.initialDirection = invalid.direction
        let engine = try TubeGameEngine(
            network: network,
            configuration: configuration,
            seed: 20
        )
        let options = Dictionary(
            uniqueKeysWithValues: engine.snapshot.availableSwipes.map {
                ($0.direction, $0)
            }
        )

        #expect(!options.isEmpty)
        #expect(options[invalid.direction] == nil)
        for direction in TubeGameDirection.allCases {
            let decision = startDecision(
                in: network,
                hub: invalid.hub,
                direction: direction
            )
            if let decision,
               decision.shouldClearQueuedDirection,
               decision.usedQueuedDirection,
               let lineID = decision.connection.lineID {
                let option = try #require(options[direction])
                #expect(option.edgeID == decision.connection.edgeID)
                #expect(option.fromStationID == decision.connection.fromStationID)
                #expect(option.toStationID == decision.connection.toStationID)
                #expect(option.lineID == lineID)
            } else {
                #expect(options[direction] == nil)
            }
        }
    }

    @MainActor
    @Test func routePreviewPersistsAcrossCommittedRailAndOverrideAndRestartClearIt() throws {
        let network = try makeNetwork()
        let oxfordCircus = try #require(network.hub(id: "940GZZLUOXC"))
        let opening = try #require(startDecision(
            in: network,
            hub: oxfordCircus,
            direction: .north
        ))
        #expect(opening.shouldClearQueuedDirection)

        var configuration = quietConfiguration()
        configuration.playerSpeed = 100
        configuration.initialDirection = .north
        let engine = try TubeGameEngine(
            network: network,
            configuration: configuration,
            seed: 23
        )
        let uncommitted = try #require(engine.snapshot.routePreview)
        engine.start()
        engine.tick(deltaTime: 0.001)

        let committed = try #require(engine.snapshot.routePreview)
        #expect(engine.snapshot.queuedDirection == nil)
        #expect(committed.isCommitted)
        #expect(committed.edgeID == uncommitted.edgeID)
        #expect(committed.fromStationID == uncommitted.fromStationID)
        #expect(committed.toStationID == uncommitted.toStationID)

        let overrideDirection = try #require(TubeGameDirection.allCases.first { direction in
            engine.queue(direction: direction)
            return engine.snapshot.routePreview != nil
                && engine.snapshot.routePreview?.direction == direction
        })
        let overridden = try #require(engine.snapshot.routePreview)
        #expect(overridden.direction == overrideDirection)
        #expect(!overridden.isCommitted)

        // Re-commit the original opening route in a fresh run, then travel far
        // enough to finish that exact oriented edge.
        engine.restart(seed: 23)
        engine.start()
        engine.tick(deltaTime: 0.001)
        let recommitted = try #require(engine.snapshot.routePreview)
        let rail = try #require(network.directedEdge(
            edgeID: recommitted.edgeID,
            fromStationID: recommitted.fromStationID
        ))
        let startStationID = oxfordCircus.representativeStationID
        let transitionLength = network.stationTransition(
            fromStationID: startStationID,
            position: try #require(network.node(stationID: startStationID)?.point),
            to: rail
        )?.playerLength ?? 0
        let completionTime = TimeInterval(
            (transitionLength + rail.playerLength) / configuration.playerSpeed
        ) + 0.02
        engine.tick(deltaTime: completionTime)
        #expect(engine.snapshot.routePreview == nil)

        engine.restart(seed: 99)
        let restarted = try #require(engine.snapshot.routePreview)
        #expect(restarted.direction == configuration.initialDirection)
        #expect(!restarted.isCommitted)
        #expect(engine.snapshot.recentStationConsumptions.isEmpty)
    }

    @MainActor
    @Test func oppositeSwipeImmediatelyReversesAnActiveRailWithoutJumpingOrRescoring() throws {
        let network = try makeNetwork()
        let oxfordCircus = try #require(network.hub(id: "940GZZLUOXC"))
        let opening = try #require(startDecision(
            in: network,
            hub: oxfordCircus,
            direction: .north
        ))
        let rail = opening.connection
        var configuration = quietConfiguration()
        configuration.playerSpeed = 100
        configuration.initialDirection = .north
        let engine = try TubeGameEngine(
            network: network,
            configuration: configuration,
            seed: 29
        )
        let startStationID = oxfordCircus.representativeStationID
        let transitionLength = network.stationTransition(
            fromStationID: startStationID,
            position: try #require(network.node(stationID: startStationID)?.point),
            to: rail
        )?.playerLength ?? 0

        engine.start()
        let distanceIntoRail = rail.playerLength * 0.35
        engine.tick(deltaTime: TimeInterval(
            (transitionLength + distanceIntoRail) / configuration.playerSpeed
        ))
        let beforeReverse = engine.snapshot
        #expect(beforeReverse.player.edgeID == rail.edgeID)
        #expect(beforeReverse.player.edgeProgress > 0.3)
        #expect(beforeReverse.player.edgeProgress < 0.4)

        let currentDirection = try #require(closestDirection(
            to: beforeReverse.player.heading
        ))
        engine.queue(direction: currentDirection.opposite)
        let reversed = engine.snapshot

        #expect(hypot(
            reversed.player.position.x - beforeReverse.player.position.x,
            reversed.player.position.y - beforeReverse.player.position.y
        ) < 0.000_001)
        #expect(
            reversed.player.heading.dx * beforeReverse.player.heading.dx
                + reversed.player.heading.dy * beforeReverse.player.heading.dy < -0.99
        )
        #expect(reversed.player.edgeID == beforeReverse.player.edgeID)
        #expect(reversed.player.destinationStationID == rail.fromStationID)
        #expect(abs(reversed.player.edgeProgress - (1 - beforeReverse.player.edgeProgress)) < 0.001)
        #expect(reversed.queuedDirection == nil)
        #expect(reversed.routePreview?.isCommitted == true)
        #expect(reversed.routePreview?.fromStationID == rail.toStationID)
        #expect(reversed.routePreview?.toStationID == rail.fromStationID)

        let positionAtReverse = reversed.player.position
        engine.tick(deltaTime: 0.05)
        let afterMovement = engine.snapshot
        let origin = rail.playerPoint(atDistance: 0)
        #expect(
            hypot(
                afterMovement.player.position.x - origin.x,
                afterMovement.player.position.y - origin.y
            ) < hypot(
                positionAtReverse.x - origin.x,
                positionAtReverse.y - origin.y
            )
        )

        engine.tick(deltaTime: TimeInterval(distanceIntoRail / configuration.playerSpeed) + 0.02)
        #expect(engine.snapshot.score == 0)
        #expect(engine.snapshot.stationsEaten == 0)
        #expect(engine.snapshot.consumedHubIDs == [oxfordCircus.id])
    }

    @MainActor
    @Test func recentConsumptionFeedCapturesEveryArrivalAndUsesGameplayTime() throws {
        let network = try makeNetwork()
        var configuration = quietConfiguration()
        configuration.duration = 20
        configuration.playerSpeed = 2_000
        let engine = try TubeGameEngine(
            network: network,
            configuration: configuration,
            seed: 31
        )
        engine.start()
        engine.tick(deltaTime: 1)

        let initialFeedback = engine.snapshot.recentStationConsumptions
        #expect(initialFeedback.count >= 2)
        #expect(initialFeedback.count <= TubeGameEngine.maximumRecentStationConsumptions)
        #expect(Set(initialFeedback.map(\.hubID)).count == initialFeedback.count)
        #expect(initialFeedback.map(\.eatenAtElapsedTime)
            == initialFeedback.map(\.eatenAtElapsedTime).sorted())
        for consumption in initialFeedback {
            #expect(consumption.hubID != "940GZZLUOXC")
            #expect(consumption.pointsAwarded > 0)
            #expect(consumption.eatenAtElapsedTime >= 0)
            #expect(consumption.eatenAtElapsedTime <= engine.snapshot.elapsedTime)
            let hub = try #require(network.hub(id: consumption.hubID))
            #expect(consumption.stationName == hub.name)
            #expect(hub.stationIDs.contains { stationID in
                network.node(stationID: stationID)?.point == consumption.position
            })
        }

        let elapsedBeforePause = engine.snapshot.elapsedTime
        engine.pause()
        engine.tick(deltaTime: 10)
        #expect(engine.snapshot.elapsedTime == elapsedBeforePause)
        #expect(engine.snapshot.recentStationConsumptions == initialFeedback)

        engine.resume()
        engine.tick(deltaTime: TubeGameEngine.stationConsumptionFeedbackDuration + 0.1)
        #expect(engine.snapshot.recentStationConsumptions.allSatisfy {
            engine.snapshot.elapsedTime - $0.eatenAtElapsedTime
                <= TubeGameEngine.stationConsumptionFeedbackDuration + 0.000_001
        })
        #expect(Set(engine.snapshot.recentStationConsumptions.map(\.hubID))
            .isDisjoint(with: Set(initialFeedback.map(\.hubID))))

        engine.restart(seed: 32)
        #expect(engine.snapshot.recentStationConsumptions.isEmpty)
    }

    @Test func sweptCollisionDetectsActorsCrossingBetweenFrames() {
        #expect(TubeGameEngine.sweptCollision(
            firstStart: CGPoint(x: 0, y: 0),
            firstEnd: CGPoint(x: 10, y: 0),
            secondStart: CGPoint(x: 10, y: 0),
            secondEnd: CGPoint(x: 0, y: 0),
            collisionDistance: 1
        ))
        #expect(!TubeGameEngine.sweptCollision(
            firstStart: CGPoint(x: 0, y: 0),
            firstEnd: CGPoint(x: 10, y: 0),
            secondStart: CGPoint(x: 10, y: 3),
            secondEnd: CGPoint(x: 0, y: 3),
            collisionDistance: 1
        ))
    }

    private func makeNetwork() throws -> TubeGameNetwork {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        return try TubeGameNetwork(graph: graph, document: document)
    }

    private func quietConfiguration() -> TubeGameConfiguration {
        var configuration = TubeGameConfiguration.standard
        configuration.countdownDuration = 0
        configuration.trainSpeed = 0
        configuration.collisionDistance = 0
        return configuration
    }

    private func closestDirection(to heading: CGVector) -> TubeGameDirection? {
        TubeGameDirection.allCases.max { lhs, rhs in
            let lhsDot = heading.dx * lhs.vector.dx + heading.dy * lhs.vector.dy
            let rhsDot = heading.dx * rhs.vector.dx + heading.dy * rhs.vector.dy
            return lhsDot < rhsDot
        }
    }

    private func findStartChoice(
        in network: TubeGameNetwork,
        directions: [TubeGameDirection],
        usedQueuedDirection: Bool
    ) -> (hub: TubeGameHub, direction: TubeGameDirection, decision: TubeGameJunctionDecision)? {
        for hub in network.hubs {
            for direction in directions {
                guard let decision = startDecision(
                    in: network,
                    hub: hub,
                    direction: direction
                ), decision.shouldClearQueuedDirection,
                   decision.usedQueuedDirection == usedQueuedDirection else {
                    continue
                }
                return (hub, direction, decision)
            }
        }
        return nil
    }

    private func startDecision(
        in network: TubeGameNetwork,
        hub: TubeGameHub,
        direction: TubeGameDirection
    ) -> TubeGameJunctionDecision? {
        let candidates = network.railConnections(fromHubID: hub.id).map {
            TubeGameJunctionCandidate(
                connection: $0,
                isReverse: false,
                isCurrentLine: false
            )
        }
        return TubeGameJunctionRouter.choose(
            candidates: candidates,
            queuedDirection: direction,
            incomingHeading: nil,
            hasCurrentLine: false,
            acceptanceDegrees: TubeGameConfiguration.standard.directionAcceptanceDegrees
        )
    }

    private func hub(id: String, lines: [TubeLineID]) -> TubeGameHub {
        TubeGameHub(
            id: id,
            name: id,
            representativeStationID: id,
            stationIDs: [id],
            lineIDs: lines,
            point: .zero
        )
    }

    private func candidate(
        id: String,
        vector: CGVector,
        isReverse: Bool = false,
        isCurrentLine: Bool = true
    ) -> TubeGameJunctionCandidate {
        let end = CGPoint(x: vector.dx * 100, y: vector.dy * 100)
        let geometry = TubeGamePathGeometry(points: [.zero, end])
        let edge = TubeGameEdge(
            id: id,
            fromStationID: "junction",
            toStationID: id,
            kind: .rail(lineID: isCurrentLine ? .central : .victoria),
            geometry: geometry,
            movementGeometry: geometry,
            fromRouteTangent: geometry.startTangent,
            toRouteTangent: geometry.endTangent
        )
        return TubeGameJunctionCandidate(
            connection: TubeGameDirectedEdge(edge: edge, isForward: true),
            isReverse: isReverse,
            isCurrentLine: isCurrentLine
        )
    }
}
