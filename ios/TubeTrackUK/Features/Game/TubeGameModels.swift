import CoreGraphics
import Foundation

enum TubeGameDirection: String, CaseIterable, Codable, Equatable, Sendable {
    case north
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
    case northWest

    var vector: CGVector {
        let diagonal = CGFloat(1 / sqrt(2.0))
        switch self {
        case .north:
            return CGVector(dx: 0, dy: -1)
        case .northEast:
            return CGVector(dx: diagonal, dy: -diagonal)
        case .east:
            return CGVector(dx: 1, dy: 0)
        case .southEast:
            return CGVector(dx: diagonal, dy: diagonal)
        case .south:
            return CGVector(dx: 0, dy: 1)
        case .southWest:
            return CGVector(dx: -diagonal, dy: diagonal)
        case .west:
            return CGVector(dx: -1, dy: 0)
        case .northWest:
            return CGVector(dx: -diagonal, dy: -diagonal)
        }
    }

    var opposite: Self {
        switch self {
        case .north: .south
        case .northEast: .southWest
        case .east: .west
        case .southEast: .northWest
        case .south: .north
        case .southWest: .northEast
        case .west: .east
        case .northWest: .southEast
        }
    }
}

enum TubeGameStartPolicy: Equatable, Sendable {
    /// Keeping the start policy explicit leaves room for a seeded-random policy
    /// without changing the engine or its callers.
    case fixed(stationID: String)

    static let oxfordCircus = Self.fixed(stationID: "940GZZLUOXC")
}

struct TubeGameConfiguration: Equatable, Sendable {
    var duration: TimeInterval
    var countdownDuration: TimeInterval
    var playerSpeed: CGFloat
    var trainSpeed: CGFloat
    var trainStationDwell: TimeInterval
    var trainTerminusDwell: TimeInterval
    var collisionDistance: CGFloat
    var maximumSimulationStep: TimeInterval
    var directionAcceptanceDegrees: Double
    var startPolicy: TubeGameStartPolicy
    var initialDirection: TubeGameDirection
    var baseStationScore: Int
    var additionalInterchangeLineScore: Int
    var sameLineStreakStepScore: Int
    var sameLineStreakBonusCap: Int

    static let standard = Self(
        duration: 60,
        countdownDuration: 3,
        playerSpeed: 110,
        trainSpeed: 75,
        trainStationDwell: 0.2,
        trainTerminusDwell: 0.65,
        collisionDistance: 40,
        maximumSimulationStep: 1.0 / 60.0,
        directionAcceptanceDegrees: 50,
        startPolicy: .oxfordCircus,
        initialDirection: .north,
        baseStationScore: 10,
        additionalInterchangeLineScore: 5,
        sameLineStreakStepScore: 2,
        sameLineStreakBonusCap: 10
    )
}

enum TubeGamePhase: Equatable, Sendable {
    case ready
    case countdown(remaining: TimeInterval)
    case playing
    case paused
    case ended(TubeGameScoreEndReason)

    var isRunInProgress: Bool {
        switch self {
        case .countdown, .playing, .paused:
            true
        case .ready, .ended:
            false
        }
    }
}

struct TubeGameScoreEvent: Equatable, Sendable {
    let hubID: String
    let lineID: TubeLineID
    let stationPoints: Int
    let streakBonus: Int

    var total: Int { stationPoints + streakBonus }
}

/// The exact rail selected by the currently buffered direction, or the rail
/// just committed at a junction until the player finishes travelling over it.
struct TubeGameRoutePreview: Equatable, Sendable {
    let direction: TubeGameDirection
    let edgeID: String
    let fromStationID: String
    let toStationID: String
    let lineID: TubeLineID
    let isCommitted: Bool
}

/// A swipe the junction router can consume at the player's next routing
/// choice, paired with the exact line that swipe selects.
struct TubeGameSwipeOption: Equatable, Sendable {
    let direction: TubeGameDirection
    let lineID: TubeLineID
    let edgeID: String
    let fromStationID: String
    let toStationID: String
}

/// A short-lived, gameplay-time-stamped record used for deterministic station
/// collection feedback. Physical hubs are collected at most once per run, so
/// the hub ID is also a stable identity for rendering.
struct TubeGameStationConsumption: Identifiable, Equatable, Sendable {
    var id: String { hubID }

    let hubID: String
    let stationName: String
    let position: CGPoint
    let lineID: TubeLineID
    let pointsAwarded: Int
    let eatenAtElapsedTime: TimeInterval
}

struct TubeGamePlayerSnapshot: Equatable, Sendable {
    let position: CGPoint
    let heading: CGVector
    let stationID: String
    let stationName: String
    let hubID: String
    let destinationStationID: String?
    let destinationStationName: String?
    let edgeID: String?
    let edgeProgress: Double
    let lineID: TubeLineID?
}

struct TubeGameTrainSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let lineID: TubeLineID
    let routeID: String
    let position: CGPoint
    let heading: CGVector
    let edgeID: String
    let edgeProgress: Double
}

struct TubeGameSnapshot: Equatable, Sendable {
    let runSeed: UInt64
    let phase: TubeGamePhase
    let configuredDuration: TimeInterval
    let elapsedTime: TimeInterval
    let remainingTime: TimeInterval
    let score: Int
    let stationsEaten: Int
    let terminusStationsReached: Int
    let completedLineIDs: Set<TubeLineID>
    let totalCollectibleStations: Int
    let sameLineStreak: Int
    let maximumSameLineStreak: Int
    let comboLineID: TubeLineID?
    let queuedDirection: TubeGameDirection?
    let routePreview: TubeGameRoutePreview?
    let availableSwipes: [TubeGameSwipeOption]
    let consumedHubIDs: Set<String>
    let lastScoreEvent: TubeGameScoreEvent?
    let recentStationConsumptions: [TubeGameStationConsumption]
    let player: TubeGamePlayerSnapshot
    let trains: [TubeGameTrainSnapshot]

    var remainingStationCount: Int {
        max(0, totalCollectibleStations - consumedHubIDs.count)
    }

    var linesCleared: Int {
        completedLineIDs.count
    }
}

struct TubeGameScoreTracker: Sendable {
    private(set) var score = 0
    private(set) var stationsEaten = 0
    private(set) var terminusStationsReached = 0
    private(set) var consumedHubIDs: Set<String> = []
    private(set) var completedLineIDs: Set<TubeLineID> = []
    private(set) var comboLineID: TubeLineID?
    private(set) var sameLineStreak = 0
    private(set) var maximumSameLineStreak = 0
    private(set) var lastEvent: TubeGameScoreEvent?

    mutating func markStartingHubConsumed(_ hubID: String) {
        consumedHubIDs.insert(hubID)
    }

    mutating func refreshCompletedLines(
        lineHubIDs: [TubeLineID: Set<String>]
    ) {
        for (lineID, requiredHubIDs) in lineHubIDs
        where !requiredHubIDs.isEmpty && requiredHubIDs.isSubset(of: consumedHubIDs) {
            completedLineIDs.insert(lineID)
        }
    }

    @discardableResult
    mutating func consume(
        hub: TubeGameHub,
        enteredOn lineID: TubeLineID,
        isTerminus: Bool = false,
        configuration: TubeGameConfiguration
    ) -> TubeGameScoreEvent? {
        guard consumedHubIDs.insert(hub.id).inserted else {
            return nil
        }

        if comboLineID == lineID {
            sameLineStreak += 1
        } else {
            comboLineID = lineID
            sameLineStreak = 1
        }
        maximumSameLineStreak = max(maximumSameLineStreak, sameLineStreak)

        let stationPoints = configuration.baseStationScore
            + max(0, hub.lineIDs.count - 1) * configuration.additionalInterchangeLineScore
        let streakBonus = min(
            configuration.sameLineStreakBonusCap,
            max(0, sameLineStreak - 1) * configuration.sameLineStreakStepScore
        )
        let event = TubeGameScoreEvent(
            hubID: hub.id,
            lineID: lineID,
            stationPoints: stationPoints,
            streakBonus: streakBonus
        )
        score += event.total
        stationsEaten += 1
        if isTerminus {
            terminusStationsReached += 1
        }
        lastEvent = event
        return event
    }
}
