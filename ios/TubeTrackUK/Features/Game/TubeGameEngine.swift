import CoreGraphics
import Foundation
import Observation

enum TubeGameEngineError: LocalizedError, Equatable {
    case invalidConfiguration
    case unavailableStartStation(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Station Chase has an invalid gameplay configuration."
        case let .unavailableStartStation(stationID):
            "Station Chase cannot start at station \(stationID)."
        }
    }
}

@MainActor
@Observable
final class TubeGameEngine {
    static let defaultRunSeed: UInt64 = 0x5354_4154_494F_4E31
    static let stationConsumptionFeedbackDuration: TimeInterval = 4
    static let maximumRecentStationConsumptions = 32

    let network: TubeGameNetwork
    let configuration: TubeGameConfiguration
    private(set) var snapshot: TubeGameSnapshot

    @ObservationIgnored private var runSeed: UInt64
    @ObservationIgnored private var phase: TubeGamePhase
    @ObservationIgnored private var elapsedTime: TimeInterval
    @ObservationIgnored private var queuedDirection: TubeGameDirection?
    @ObservationIgnored private var committedRoutePreview: TubeGameRoutePreview?
    @ObservationIgnored private var cachedRoutePreview: TubeGameRoutePreview?
    @ObservationIgnored private var routePreviewNeedsResolution: Bool
    @ObservationIgnored private var recentStationConsumptions: [TubeGameStationConsumption]
    @ObservationIgnored private var scoreTracker: TubeGameScoreTracker
    @ObservationIgnored private var player: PlayerState
    @ObservationIgnored private var trainSimulation: TubeGameTrainSimulation

    init(
        network: TubeGameNetwork,
        configuration: TubeGameConfiguration = .standard,
        seed: UInt64 = TubeGameEngine.defaultRunSeed
    ) throws {
        guard Self.isValid(configuration) else {
            throw TubeGameEngineError.invalidConfiguration
        }
        let start = try Self.resolveStart(in: network, policy: configuration.startPolicy)
        var scoreTracker = TubeGameScoreTracker()
        scoreTracker.markStartingHubConsumed(start.hub.id)
        let player = PlayerState(
            currentStationID: start.node.stationID,
            position: start.node.point,
            heading: configuration.initialDirection.vector
        )
        let trains = TubeGameTrainSimulation(
            network: network,
            seed: seed,
            startHubID: start.hub.id,
            configuration: configuration
        )
        let initialRoutePreview = Self.resolveRoutePreview(
            network: network,
            configuration: configuration,
            queuedDirection: configuration.initialDirection,
            committedRoutePreview: nil,
            player: player
        )

        self.network = network
        self.configuration = configuration
        runSeed = seed
        phase = .ready
        elapsedTime = 0
        queuedDirection = configuration.initialDirection
        committedRoutePreview = nil
        cachedRoutePreview = initialRoutePreview
        routePreviewNeedsResolution = false
        recentStationConsumptions = []
        self.scoreTracker = scoreTracker
        self.player = player
        trainSimulation = trains
        snapshot = Self.makeSnapshot(
            network: network,
            configuration: configuration,
            runSeed: seed,
            phase: .ready,
            elapsedTime: 0,
            queuedDirection: configuration.initialDirection,
            routePreview: initialRoutePreview,
            scoreTracker: scoreTracker,
            recentStationConsumptions: [],
            player: player,
            trains: trains.snapshots
        )
    }

    func start() {
        switch phase {
        case .ready:
            beginCountdownOrPlay()
        case .ended:
            restart(seed: runSeed)
            beginCountdownOrPlay()
        case .countdown, .playing, .paused:
            return
        }
        publishSnapshot()
    }

    func restart(seed: UInt64? = nil) {
        let nextSeed = seed ?? runSeed
        guard let start = try? Self.resolveStart(in: network, policy: configuration.startPolicy) else {
            return
        }
        var tracker = TubeGameScoreTracker()
        tracker.markStartingHubConsumed(start.hub.id)

        runSeed = nextSeed
        phase = .ready
        elapsedTime = 0
        queuedDirection = configuration.initialDirection
        committedRoutePreview = nil
        cachedRoutePreview = nil
        routePreviewNeedsResolution = true
        recentStationConsumptions = []
        scoreTracker = tracker
        player = PlayerState(
            currentStationID: start.node.stationID,
            position: start.node.point,
            heading: configuration.initialDirection.vector
        )
        trainSimulation = TubeGameTrainSimulation(
            network: network,
            seed: nextSeed,
            startHubID: start.hub.id,
            configuration: configuration
        )
        publishSnapshot()
    }

    func queue(direction: TubeGameDirection) {
        if case .ended = phase { return }
        if reversePlayerIfNeeded(for: direction) {
            publishSnapshot()
            return
        }
        guard queuedDirection != direction || committedRoutePreview != nil else { return }
        queuedDirection = direction
        committedRoutePreview = nil
        routePreviewNeedsResolution = true
        publishSnapshot()
    }

    func tick(deltaTime: TimeInterval) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        var remainingDelta = deltaTime
        var phaseSafetyCounter = 0

        while remainingDelta > 0, phaseSafetyCounter < 4 {
            phaseSafetyCounter += 1
            switch phase {
            case let .countdown(remaining):
                let countdownSlice = min(remainingDelta, max(0, remaining))
                remainingDelta -= countdownSlice
                let nextRemaining = max(0, remaining - countdownSlice)
                if nextRemaining > 0 {
                    phase = .countdown(remaining: nextRemaining)
                    remainingDelta = 0
                } else {
                    phase = .playing
                }

            case .playing:
                advancePlaying(by: remainingDelta)
                remainingDelta = 0

            case .ready, .paused, .ended:
                remainingDelta = 0
            }
        }
        publishSnapshot()
    }

    func pause() {
        switch phase {
        case .playing, .countdown:
            phase = .paused
            publishSnapshot()
        case .ready, .paused, .ended:
            break
        }
    }

    func resume() {
        guard phase == .paused else { return }
        beginCountdownOrPlay()
        publishSnapshot()
    }

    func quit() {
        guard phase.isRunInProgress else { return }
        phase = .ended(.manualQuit)
        publishSnapshot()
    }

    func scoreRecord(playedAt: Date = Date()) -> TubeGameScoreRecord? {
        guard case let .ended(reason) = snapshot.phase else { return nil }
        return TubeGameScoreRecord(
            score: snapshot.score,
            stationsEaten: snapshot.stationsEaten,
            maxCombo: snapshot.maximumSameLineStreak,
            configuredDuration: snapshot.configuredDuration,
            elapsedTime: snapshot.elapsedTime,
            endReason: reason,
            playedAt: playedAt,
            runSeed: snapshot.runSeed,
            graphGeneratedAt: network.graphGeneratedAt
        )
    }

    private func beginCountdownOrPlay() {
        phase = configuration.countdownDuration > 0
            ? .countdown(remaining: configuration.countdownDuration)
            : .playing
    }

    private func advancePlaying(by deltaTime: TimeInterval) {
        var remainingDelta = deltaTime
        var safetyCounter = 0
        let maximumSteps = max(
            1,
            Int(ceil(min(deltaTime, configuration.duration) / configuration.maximumSimulationStep)) + 2
        )

        while remainingDelta > 0, phase == .playing, safetyCounter < maximumSteps {
            safetyCounter += 1
            let sessionTimeRemaining = max(0, configuration.duration - elapsedTime)
            guard sessionTimeRemaining > 0 else {
                phase = .ended(.completed)
                break
            }
            let step = min(
                remainingDelta,
                configuration.maximumSimulationStep,
                sessionTimeRemaining
            )
            guard step > 0 else { break }

            let previousPlayerPosition = player.position
            let previousTrainPositions = Dictionary(
                uniqueKeysWithValues: trainSimulation.snapshots.map { ($0.id, $0.position) }
            )
            advancePlayer(
                distance: configuration.playerSpeed * CGFloat(step),
                startingElapsedTime: elapsedTime
            )
            trainSimulation.advance(by: step)
            elapsedTime = min(configuration.duration, elapsedTime + step)
            pruneRecentStationConsumptions()
            remainingDelta = max(0, remainingDelta - step)

            let playerPosition = player.position
            // A zero radius is an explicit collision-off setting used by
            // deterministic previews/tests; normal gameplay always supplies
            // a positive hit radius.
            let collided = configuration.collisionDistance > 0
                && trainSimulation.snapshots.contains { train in
                let previousTrainPosition = previousTrainPositions[train.id] ?? train.position
                return Self.sweptCollision(
                    firstStart: previousPlayerPosition,
                    firstEnd: playerPosition,
                    secondStart: previousTrainPosition,
                    secondEnd: train.position,
                    collisionDistance: configuration.collisionDistance
                )
            }
            if collided {
                phase = .ended(.collision)
            } else if scoreTracker.consumedHubIDs.count == network.collectibleHubCount {
                phase = .ended(.networkCleared)
            } else if elapsedTime >= configuration.duration {
                elapsedTime = configuration.duration
                phase = .ended(.completed)
            }
        }
    }

    private func advancePlayer(
        distance: CGFloat,
        startingElapsedTime: TimeInterval
    ) {
        guard distance.isFinite, distance > 0 else { return }
        let initialDistance = distance
        var remainingDistance = distance
        var safetyCounter = 0

        while remainingDistance > 0, safetyCounter < 128 {
            safetyCounter += 1
            if player.traversal == nil {
                if let pendingRail = player.pendingRail {
                    player.pendingRail = nil
                    startPlayerTraversal(pendingRail)
                } else {
                    guard selectAndStartNextPlayerConnection() else { break }
                }
            }
            guard let traversal = player.traversal else { break }

            if traversal.playerLength <= 0.000_001 {
                completePlayerTraversal(
                    traversal,
                    atElapsedTime: arrivalTime(
                        startingElapsedTime: startingElapsedTime,
                        distanceTravelled: initialDistance - remainingDistance
                    )
                )
                continue
            }
            let distanceAvailable = max(0, traversal.playerLength - player.distanceOnTraversal)
            let movement = min(remainingDistance, distanceAvailable)
            player.distanceOnTraversal += movement
            remainingDistance -= movement
            player.position = traversal.playerPoint(atDistance: player.distanceOnTraversal)
            player.heading = traversal.playerTangent(atDistance: player.distanceOnTraversal)

            if player.distanceOnTraversal + 0.000_001 >= traversal.playerLength {
                player.distanceOnTraversal = traversal.playerLength
                player.position = traversal.playerPoint(atDistance: traversal.playerLength)
                completePlayerTraversal(
                    traversal,
                    atElapsedTime: arrivalTime(
                        startingElapsedTime: startingElapsedTime,
                        distanceTravelled: initialDistance - remainingDistance
                    )
                )
            }
        }
    }

    private func reversePlayerIfNeeded(for direction: TubeGameDirection) -> Bool {
        guard let traversal = player.traversal,
              let lineID = traversal.lineID,
              hypot(player.heading.dx, player.heading.dy) > 0.000_001,
              let currentDirection = TubeGameDirection.allCases.max(by: {
                  player.heading.dot($0.vector) < player.heading.dot($1.vector)
              }),
              direction == currentDirection.opposite else {
            return false
        }

        let position = player.position
        let reversedTraversal = TubeGameDirectedEdge(
            edge: traversal.edge,
            isForward: !traversal.isForward
        )
        let reversedDistance = max(
            0,
            reversedTraversal.playerLength - player.distanceOnTraversal
        )

        player.traversal = reversedTraversal
        player.distanceOnTraversal = reversedDistance
        player.position = position
        player.heading = reversedTraversal.playerTangent(atDistance: reversedDistance)
        player.pendingRail = nil
        player.currentLineID = lineID
        queuedDirection = nil
        committedRoutePreview = TubeGameRoutePreview(
            direction: direction,
            edgeID: reversedTraversal.edgeID,
            fromStationID: reversedTraversal.fromStationID,
            toStationID: reversedTraversal.toStationID,
            lineID: lineID,
            isCommitted: true
        )
        routePreviewNeedsResolution = true
        return true
    }

    private func selectAndStartNextPlayerConnection() -> Bool {
        guard let currentNode = network.node(stationID: player.currentStationID) else { return false }
        let connections = network.railConnections(fromHubID: currentNode.hubID)
        let candidates = connections.map { connection in
            TubeGameJunctionCandidate(
                connection: connection,
                isReverse: connection.edgeID == player.previousRailEdgeID
                    && connection.toStationID == player.previousRailOriginStationID,
                isCurrentLine: connection.lineID == player.currentLineID
            )
        }
        guard let decision = TubeGameJunctionRouter.choose(
            candidates: candidates,
            queuedDirection: queuedDirection,
            incomingHeading: player.incomingHeading,
            hasCurrentLine: player.currentLineID != nil,
            acceptanceDegrees: configuration.directionAcceptanceDegrees
        ) else { return false }

        let directionAtDecision = queuedDirection
        let rail = decision.connection
        if decision.shouldClearQueuedDirection {
            queuedDirection = nil
            if let directionAtDecision,
               let lineID = rail.lineID {
                committedRoutePreview = TubeGameRoutePreview(
                    direction: directionAtDecision,
                    edgeID: rail.edgeID,
                    fromStationID: rail.fromStationID,
                    toStationID: rail.toStationID,
                    lineID: lineID,
                    isCommitted: true
                )
            }
            routePreviewNeedsResolution = true
        }
        if let transition = network.stationTransition(
            fromStationID: player.currentStationID,
            position: player.position,
            to: rail
        ) {
            player.pendingRail = rail
            startPlayerTraversal(transition)
        } else {
            startPlayerTraversal(rail)
        }
        return true
    }

    private func startPlayerTraversal(_ traversal: TubeGameDirectedEdge) {
        player.traversal = traversal
        player.distanceOnTraversal = 0
        player.position = traversal.playerPoint(atDistance: 0)
        player.heading = traversal.outgoingTangent
        if let lineID = traversal.lineID {
            player.currentLineID = lineID
        }
    }

    private func completePlayerTraversal(
        _ traversal: TubeGameDirectedEdge,
        atElapsedTime arrivalElapsedTime: TimeInterval
    ) {
        player.currentStationID = traversal.toStationID
        player.position = traversal.playerPoint(atDistance: traversal.playerLength)
        player.traversal = nil
        player.distanceOnTraversal = 0

        guard let lineID = traversal.lineID else { return }
        if committedRoutePreview?.edgeID == traversal.edgeID,
           committedRoutePreview?.fromStationID == traversal.fromStationID,
           committedRoutePreview?.toStationID == traversal.toStationID {
            committedRoutePreview = nil
            routePreviewNeedsResolution = true
        }
        player.currentLineID = lineID
        player.previousRailEdgeID = traversal.edgeID
        player.previousRailOriginStationID = traversal.fromStationID
        player.incomingHeading = traversal.incomingTangent
        guard let node = network.node(stationID: traversal.toStationID),
              let hub = network.hub(id: node.hubID) else { return }
        guard let scoreEvent = scoreTracker.consume(
            hub: hub,
            enteredOn: lineID,
            configuration: configuration
        ) else { return }
        recentStationConsumptions.append(TubeGameStationConsumption(
            hubID: hub.id,
            stationName: hub.name,
            position: player.position,
            lineID: lineID,
            pointsAwarded: scoreEvent.total,
            eatenAtElapsedTime: arrivalElapsedTime
        ))
        if recentStationConsumptions.count > Self.maximumRecentStationConsumptions {
            recentStationConsumptions.removeFirst(
                recentStationConsumptions.count - Self.maximumRecentStationConsumptions
            )
        }
    }

    private func arrivalTime(
        startingElapsedTime: TimeInterval,
        distanceTravelled: CGFloat
    ) -> TimeInterval {
        guard configuration.playerSpeed > 0 else { return startingElapsedTime }
        let travelTime = TimeInterval(max(0, distanceTravelled) / configuration.playerSpeed)
        return min(configuration.duration, startingElapsedTime + travelTime)
    }

    private func pruneRecentStationConsumptions() {
        let cutoff = elapsedTime - Self.stationConsumptionFeedbackDuration
        recentStationConsumptions.removeAll { $0.eatenAtElapsedTime < cutoff }
    }

    private func publishSnapshot() {
        if routePreviewNeedsResolution {
            cachedRoutePreview = Self.resolveRoutePreview(
                network: network,
                configuration: configuration,
                queuedDirection: queuedDirection,
                committedRoutePreview: committedRoutePreview,
                player: player
            )
            routePreviewNeedsResolution = false
        }
        snapshot = Self.makeSnapshot(
            network: network,
            configuration: configuration,
            runSeed: runSeed,
            phase: phase,
            elapsedTime: elapsedTime,
            queuedDirection: queuedDirection,
            routePreview: cachedRoutePreview,
            scoreTracker: scoreTracker,
            recentStationConsumptions: recentStationConsumptions,
            player: player,
            trains: trainSimulation.snapshots
        )
    }

    private static func makeSnapshot(
        network: TubeGameNetwork,
        configuration: TubeGameConfiguration,
        runSeed: UInt64,
        phase: TubeGamePhase,
        elapsedTime: TimeInterval,
        queuedDirection: TubeGameDirection?,
        routePreview: TubeGameRoutePreview?,
        scoreTracker: TubeGameScoreTracker,
        recentStationConsumptions: [TubeGameStationConsumption],
        player: PlayerState,
        trains: [TubeGameTrainSnapshot]
    ) -> TubeGameSnapshot {
        let node = network.node(stationID: player.currentStationID)
        let traversal = player.traversal
        let playerSnapshot = TubeGamePlayerSnapshot(
            position: player.position,
            heading: player.heading,
            stationID: player.currentStationID,
            stationName: node?.name ?? "Unknown station",
            hubID: node?.hubID ?? player.currentStationID,
            destinationStationID: traversal?.toStationID,
            destinationStationName: traversal
                .flatMap { network.node(stationID: $0.toStationID)?.name },
            edgeID: traversal?.edgeID,
            edgeProgress: traversal?.playerProgress(
                atDistance: player.distanceOnTraversal
            ) ?? 0,
            lineID: player.currentLineID
        )
        return TubeGameSnapshot(
            runSeed: runSeed,
            phase: phase,
            configuredDuration: configuration.duration,
            elapsedTime: elapsedTime,
            remainingTime: max(0, configuration.duration - elapsedTime),
            score: scoreTracker.score,
            stationsEaten: scoreTracker.stationsEaten,
            totalCollectibleStations: network.collectibleHubCount,
            sameLineStreak: scoreTracker.sameLineStreak,
            maximumSameLineStreak: scoreTracker.maximumSameLineStreak,
            comboLineID: scoreTracker.comboLineID,
            queuedDirection: queuedDirection,
            routePreview: routePreview,
            consumedHubIDs: scoreTracker.consumedHubIDs,
            lastScoreEvent: scoreTracker.lastEvent,
            recentStationConsumptions: recentStationConsumptions,
            player: playerSnapshot,
            trains: trains
        )
    }

    private static func resolveRoutePreview(
        network: TubeGameNetwork,
        configuration: TubeGameConfiguration,
        queuedDirection: TubeGameDirection?,
        committedRoutePreview: TubeGameRoutePreview?,
        player: PlayerState
    ) -> TubeGameRoutePreview? {
        guard let queuedDirection else { return committedRoutePreview }

        // A queued input always describes the next routing decision. While a
        // rail (or the transfer leading to a selected rail) is in progress,
        // evaluate the junction at that rail's destination using the incoming
        // rail as the prospective routing history.
        let prospectiveRail: TubeGameDirectedEdge?
        if let pendingRail = player.pendingRail {
            prospectiveRail = pendingRail
        } else if let traversal = player.traversal, traversal.lineID != nil {
            prospectiveRail = traversal
        } else {
            prospectiveRail = nil
        }

        var stationID = prospectiveRail?.toStationID ?? player.currentStationID
        var previousRailEdgeID = prospectiveRail?.edgeID ?? player.previousRailEdgeID
        var previousRailOriginStationID = prospectiveRail?.fromStationID
            ?? player.previousRailOriginStationID
        var incomingHeading = prospectiveRail?.incomingTangent ?? player.incomingHeading
        var currentLineID = prospectiveRail?.lineID ?? player.currentLineID
        var visitedRoutingStates: Set<String> = []

        // Walk across automatic degree-two continuations. They retain the
        // buffered direction and therefore are not the route selected by the
        // swipe. The preview begins at the first genuine choice (or explicit
        // U-turn) where the router will actually consume/clear that intent.
        for _ in 0 ... network.edges.count {
            let routingState = [
                stationID,
                previousRailEdgeID ?? "-",
                previousRailOriginStationID ?? "-",
                currentLineID?.rawValue ?? "-"
            ].joined(separator: "|")
            guard visitedRoutingStates.insert(routingState).inserted,
                  let node = network.node(stationID: stationID) else {
                return nil
            }
            let candidates = network.railConnections(fromHubID: node.hubID).map { connection in
                TubeGameJunctionCandidate(
                    connection: connection,
                    isReverse: connection.edgeID == previousRailEdgeID
                        && connection.toStationID == previousRailOriginStationID,
                    isCurrentLine: connection.lineID == currentLineID
                )
            }
            guard let decision = TubeGameJunctionRouter.choose(
                candidates: candidates,
                queuedDirection: queuedDirection,
                incomingHeading: incomingHeading,
                hasCurrentLine: currentLineID != nil,
                acceptanceDegrees: configuration.directionAcceptanceDegrees
            ), let lineID = decision.connection.lineID else {
                return nil
            }
            let connection = decision.connection
            if decision.shouldClearQueuedDirection {
                return TubeGameRoutePreview(
                    direction: queuedDirection,
                    edgeID: connection.edgeID,
                    fromStationID: connection.fromStationID,
                    toStationID: connection.toStationID,
                    lineID: lineID,
                    isCommitted: false
                )
            }

            stationID = connection.toStationID
            previousRailEdgeID = connection.edgeID
            previousRailOriginStationID = connection.fromStationID
            incomingHeading = connection.incomingTangent
            currentLineID = lineID
        }
        return nil
    }

    private static func resolveStart(
        in network: TubeGameNetwork,
        policy: TubeGameStartPolicy
    ) throws -> (node: TubeGameNode, hub: TubeGameHub) {
        switch policy {
        case let .fixed(stationID):
            let node: TubeGameNode?
            if let exactNode = network.node(stationID: stationID) {
                node = exactNode
            } else if let hub = network.hub(id: stationID) {
                node = network.node(stationID: hub.representativeStationID)
            } else {
                node = nil
            }
            guard let node, let hub = network.hub(id: node.hubID) else {
                throw TubeGameEngineError.unavailableStartStation(stationID)
            }
            return (node, hub)
        }
    }

    private static func isValid(_ configuration: TubeGameConfiguration) -> Bool {
        configuration.duration.isFinite
            && configuration.duration > 0
            && configuration.countdownDuration.isFinite
            && configuration.countdownDuration >= 0
            && configuration.playerSpeed.isFinite
            && configuration.playerSpeed >= 0
            && configuration.trainSpeed.isFinite
            && configuration.trainSpeed >= 0
            && configuration.trainStationDwell.isFinite
            && configuration.trainStationDwell >= 0
            && configuration.trainTerminusDwell.isFinite
            && configuration.trainTerminusDwell >= 0
            && configuration.collisionDistance.isFinite
            && configuration.collisionDistance >= 0
            && configuration.maximumSimulationStep.isFinite
            && configuration.maximumSimulationStep > 0
            && configuration.directionAcceptanceDegrees.isFinite
            && (0 ... 180).contains(configuration.directionAcceptanceDegrees)
            && configuration.baseStationScore >= 0
            && configuration.additionalInterchangeLineScore >= 0
            && configuration.sameLineStreakStepScore >= 0
            && configuration.sameLineStreakBonusCap >= 0
    }

    nonisolated static func sweptCollision(
        firstStart: CGPoint,
        firstEnd: CGPoint,
        secondStart: CGPoint,
        secondEnd: CGPoint,
        collisionDistance: CGFloat
    ) -> Bool {
        guard collisionDistance >= 0 else { return false }
        let relativeStart = CGVector(
            dx: firstStart.x - secondStart.x,
            dy: firstStart.y - secondStart.y
        )
        let relativeVelocity = CGVector(
            dx: (firstEnd.x - firstStart.x) - (secondEnd.x - secondStart.x),
            dy: (firstEnd.y - firstStart.y) - (secondEnd.y - secondStart.y)
        )
        let speedSquared = relativeVelocity.dx * relativeVelocity.dx
            + relativeVelocity.dy * relativeVelocity.dy
        let closestTime: CGFloat
        if speedSquared > 0 {
            closestTime = min(
                1,
                max(
                    0,
                    -(relativeStart.dx * relativeVelocity.dx
                        + relativeStart.dy * relativeVelocity.dy) / speedSquared
                )
            )
        } else {
            closestTime = 0
        }
        let closestX = relativeStart.dx + relativeVelocity.dx * closestTime
        let closestY = relativeStart.dy + relativeVelocity.dy * closestTime
        return closestX * closestX + closestY * closestY
            <= collisionDistance * collisionDistance
    }
}

private extension TubeGameEngine {
    struct PlayerState: Sendable {
        var currentStationID: String
        var position: CGPoint
        var heading: CGVector
        var traversal: TubeGameDirectedEdge?
        var distanceOnTraversal: CGFloat
        var pendingRail: TubeGameDirectedEdge?
        var currentLineID: TubeLineID?
        var previousRailEdgeID: String?
        var previousRailOriginStationID: String?
        var incomingHeading: CGVector?

        init(currentStationID: String, position: CGPoint, heading: CGVector) {
            self.currentStationID = currentStationID
            self.position = position
            self.heading = heading
            traversal = nil
            distanceOnTraversal = 0
            pendingRail = nil
            currentLineID = nil
            previousRailEdgeID = nil
            previousRailOriginStationID = nil
            incomingHeading = nil
        }
    }
}

struct TubeGameJunctionCandidate: Sendable {
    let connection: TubeGameDirectedEdge
    let isReverse: Bool
    let isCurrentLine: Bool
}

struct TubeGameJunctionDecision: Sendable {
    let connection: TubeGameDirectedEdge
    let usedQueuedDirection: Bool
    /// Successful intents are consumed. An unavailable intent is also cleared
    /// at a genuine multi-choice junction so it cannot trigger a surprise turn
    /// several stations later; ordinary straight-through stations retain it.
    let shouldClearQueuedDirection: Bool
}

enum TubeGameJunctionRouter {
    static func choose(
        candidates: [TubeGameJunctionCandidate],
        queuedDirection: TubeGameDirection?,
        incomingHeading: CGVector?,
        hasCurrentLine: Bool,
        acceptanceDegrees: Double = 33.75
    ) -> TubeGameJunctionDecision? {
        guard !candidates.isEmpty else { return nil }

        let nonReversingCandidates = candidates.filter { !$0.isReverse }
        let reversingCandidates = candidates.filter(\.isReverse)
        let hasGenuineChoice = nonReversingCandidates.count > 1

        if let queuedDirection {
            let minimumDot = cos(acceptanceDegrees * .pi / 180)
            let directionVector = queuedDirection.vector
            // A single forward continuation is automatic and must not consume
            // the buffered intent, even when its tangent happens to match. A
            // matching reverse remains an explicit U-turn when forward travel
            // is also available. Termini reverse automatically without
            // consuming the intent. Genuine branches evaluate every exit.
            let matchableCandidates: [TubeGameJunctionCandidate]
            if hasGenuineChoice {
                matchableCandidates = candidates
            } else if !nonReversingCandidates.isEmpty {
                matchableCandidates = reversingCandidates
            } else {
                matchableCandidates = []
            }
            let matching = matchableCandidates.compactMap { candidate -> AngledCandidate? in
                guard let tangent = candidate.connection.outgoingTangent.normalized else { return nil }
                let dot = Double(tangent.dot(directionVector))
                guard dot + 0.000_001 >= minimumDot else { return nil }
                return AngledCandidate(
                    candidate: candidate,
                    angle: acos(min(1.0, max(-1.0, dot)))
                )
            }.sorted(by: angledCandidateSort)
            if let selected = matching.first?.candidate {
                return TubeGameJunctionDecision(
                    connection: selected.connection,
                    usedQueuedDirection: true,
                    shouldClearQueuedDirection: true
                )
            }
        }

        var fallback = hasCurrentLine ? candidates.filter(\.isCurrentLine) : candidates
        if fallback.isEmpty { fallback = candidates }
        let nonReversing = fallback.filter { !$0.isReverse }
        if !nonReversing.isEmpty { fallback = nonReversing }

        let incoming = incomingHeading?.normalized
        let selected = fallback.sorted { lhs, rhs in
            if let incoming,
               let lhsTangent = lhs.connection.outgoingTangent.normalized,
               let rhsTangent = rhs.connection.outgoingTangent.normalized {
                let lhsStraightness = incoming.dot(lhsTangent)
                let rhsStraightness = incoming.dot(rhsTangent)
                if abs(lhsStraightness - rhsStraightness) > 0.000_001 {
                    return lhsStraightness > rhsStraightness
                }
            }
            if lhs.isReverse != rhs.isReverse { return !lhs.isReverse }
            if lhs.isCurrentLine != rhs.isCurrentLine { return lhs.isCurrentLine }
            if lhs.connection.edgeID != rhs.connection.edgeID {
                return lhs.connection.edgeID < rhs.connection.edgeID
            }
            return lhs.connection.toStationID < rhs.connection.toStationID
        }.first
        return selected.map {
            TubeGameJunctionDecision(
                connection: $0.connection,
                usedQueuedDirection: false,
                shouldClearQueuedDirection: queuedDirection != nil && hasGenuineChoice
            )
        }
    }

    private static func angledCandidateSort(_ lhs: AngledCandidate, _ rhs: AngledCandidate) -> Bool {
        if abs(lhs.angle - rhs.angle) > 0.000_001 { return lhs.angle < rhs.angle }
        if lhs.candidate.isReverse != rhs.candidate.isReverse { return !lhs.candidate.isReverse }
        if lhs.candidate.isCurrentLine != rhs.candidate.isCurrentLine {
            return lhs.candidate.isCurrentLine
        }
        if lhs.candidate.connection.edgeID != rhs.candidate.connection.edgeID {
            return lhs.candidate.connection.edgeID < rhs.candidate.connection.edgeID
        }
        return lhs.candidate.connection.toStationID < rhs.candidate.connection.toStationID
    }

    private struct AngledCandidate {
        let candidate: TubeGameJunctionCandidate
        let angle: Double
    }
}

private extension CGVector {
    var normalized: Self? {
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return Self(dx: dx / length, dy: dy / length)
    }

    func dot(_ other: Self) -> CGFloat {
        dx * other.dx + dy * other.dy
    }
}
