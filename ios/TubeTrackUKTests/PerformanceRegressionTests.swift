import Foundation
import Testing
@testable import TubeTrackUK

struct PerformanceRegressionTests {
    @Test func startupInterstitialIsFullyDismissedWithinTwoAndAHalfSeconds() {
        #expect(AppStartupTiming.maximumInterstitialDuration == 2.5)
        #expect(AppStartupTiming.interstitialFadeDuration >= 0)
        #expect(AppStartupTiming.revealDeadline >= 0)
        #expect(
            AppStartupTiming.revealDeadline
                + AppStartupTiming.interstitialFadeDuration
                <= AppStartupTiming.maximumInterstitialDuration
        )
    }

    @Test func defaultAPISessionUsesProtocolCachingWithoutPersistentResponseData() throws {
        let configuration = TubeTrackAPIClient.defaultSessionConfiguration()
        let cache = try #require(configuration.urlCache)

        #expect(cache.memoryCapacity == 16 * 1_024 * 1_024)
        #expect(cache.diskCapacity == 0)
        #expect(configuration.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test func allLiveTrainLinesAreRequestedInDeterministicOrder() {
        let requestedLines = TubeTrainRequestBatcher.requestedLines(for: [])

        #expect(requestedLines == requestedLines.sorted { $0.rawValue < $1.rawValue })
        #expect(requestedLines.contains(.dlr))
        #expect(requestedLines.contains(.tram))
        #expect(requestedLines.count == TubeLineID.allCases.filter(\.supportsEstimatedTrains).count)
    }

    @Test func explicitLiveTrainFilterIsSortedAndDropsUnsupportedLines() {
        let requestedLines = TubeTrainRequestBatcher.requestedLines(
            for: [.victoria, .tram, .dlr, .bakerloo, .central]
        )
        #expect(requestedLines == [.bakerloo, .central, .dlr, .tram, .victoria])
    }

    @Test func liveTrainFilterPillsAreAlphabeticalByPassengerFacingName() {
        let names = TubeLineID.liveTrainFilterCases.map(\.displayName)
        let alphabetizedNames = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        #expect(names == alphabetizedNames)
        #expect(names.first == "Bakerloo")
        #expect(names.last == "Windrush line")
    }

    @Test func mapOptionsExposeStateAwareActionLabels() {
        #expect(MapPresentationMode.beck.switchActionTitle == "Show map view")
        #expect(MapPresentationMode.realWorld.switchActionTitle == "Show line view")
        #expect(MapPresentationMode.beck.toggled.toggleNoticeMessage == "Toggling map view")
        #expect(
            MapPresentationMode.realWorld.toggled.toggleNoticeMessage
                == "Toggling network view"
        )
        #expect(AppAppearanceMode.system.actionTitle == "Use system appearance")
        #expect(AppAppearanceMode.light.actionTitle == "Enable light mode")
        #expect(AppAppearanceMode.dark.actionTitle == "Enable dark mode")
    }

    @Test func lightweightLivePredictionIgnoresUnusedDatePayload() throws {
        let json = """
        [{
          "id": "prediction-id",
          "vehicleId": "train-42",
          "lineId": "victoria",
          "naptanId": "940GZZLUVIC",
          "direction": "southbound",
          "destinationName": "Brixton",
          "destinationNaptanId": "940GZZLUBXN",
          "towards": "Brixton",
          "expectedArrival": "intentionally-not-a-date",
          "timeToStation": 75,
          "currentLocation": "Between stations",
          "stationName": "Unused station name",
          "platformName": "Unused platform"
        }]
        """

        let predictions = try JSONDecoder.tfl.decode(
            [TfLLiveTrainPrediction].self,
            from: Data(json.utf8)
        )

        let prediction = try #require(predictions.first)
        #expect(prediction.vehicleId == "train-42")
        #expect(prediction.lineId == TubeLineID.victoria.rawValue)
        #expect(prediction.timeToStation == 75)
        #expect(prediction.platformName == "Unused platform")
    }

    @Test func ambiguousTramMergeIsHiddenUntilVehicleContextDisambiguatesIt() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let now = Date(timeIntervalSince1970: 1_000)
        let predictions = [
            tramPrediction(
                stationID: "940GZZCRSAN",
                seconds: 20,
                destinationName: "George Street Crossover"
            ),
            tramPrediction(
                stationID: "940GZZCRLEB",
                seconds: 80,
                destinationName: "George Street Crossover"
            ),
            tramPrediction(
                stationID: "940GZZCRECR",
                seconds: 150,
                destinationName: "George Street Crossover"
            ),
        ]

        let ambiguous = TramVehicleRouteResolver.resolve(
            vehicleID: "2533",
            predictions: predictions,
            repository: repository,
            previousContext: nil,
            now: now
        )
        #expect(ambiguous?.train.id == nil)

        let contextual = TramVehicleRouteResolver.resolve(
            vehicleID: "2533",
            predictions: predictions,
            repository: repository,
            previousContext: TramVehicleRouteContext(
                routeIndex: 3,
                previousStationID: "940GZZCRCOO",
                nextStationID: "940GZZCRLOY",
                updatedAt: now.addingTimeInterval(-30)
            ),
            now: now
        )
        let train = try #require(contextual?.train)
        #expect(train.previousStationID == "940GZZCRLOY")
        #expect(train.nextStationID == "940GZZCRSAN")
        #expect(contextual?.context.routeIndex == 3)

        let expired = TramVehicleRouteResolver.resolve(
            vehicleID: "2533",
            predictions: predictions,
            repository: repository,
            previousContext: TramVehicleRouteContext(
                routeIndex: 3,
                previousStationID: "940GZZCRCOO",
                nextStationID: "940GZZCRLOY",
                updatedAt: now.addingTimeInterval(-(TramVehicleRouteResolver.contextLifetime + 1))
            ),
            now: now
        )
        #expect(expired?.train.id == nil)
    }

    @Test func tramTerminalPredictionStartsOnOutgoingSegment() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let resolution = TramVehicleRouteResolver.resolve(
            vehicleID: "2541",
            predictions: [
                tramPrediction(
                    stationID: "940GZZCRNWA",
                    seconds: 0,
                    destinationName: "Church Street",
                    destinationStationID: "940GZZCRCHR"
                ),
                tramPrediction(
                    stationID: "940GZZCRKGH",
                    seconds: 65,
                    destinationName: "Church Street",
                    destinationStationID: "940GZZCRCHR"
                ),
            ],
            repository: repository,
            previousContext: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )

        let train = try #require(resolution?.train)
        #expect(train.previousStationID == "940GZZCRNWA")
        #expect(train.nextStationID == "940GZZCRKGH")
        #expect(train.progress == 0.05)
        #expect(train.secondsToNextStation == 65)
    }

    @Test func futureScheduledTramDoesNotBecomeAPhysicalMarker() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let resolution = TramVehicleRouteResolver.resolve(
            vehicleID: "future-2530",
            predictions: [
                tramPrediction(
                    stationID: "940GZZCRBIR",
                    seconds: LiveTrainMarkerPolicy.maximumLightRailSecondsToNearestStation + 1,
                    destinationName: "Beckenham Junction",
                    destinationStationID: "940GZZCRBEK"
                ),
            ],
            repository: repository,
            previousContext: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )

        #expect(resolution == nil)
    }

    @Test func tramResolverFollowsTheOneWayCroydonLoop() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let resolution = TramVehicleRouteResolver.resolve(
            vehicleID: "2550",
            predictions: [
                tramPrediction(
                    stationID: "940GZZCRWEL",
                    seconds: 24,
                    destinationName: "Beckenham Junction",
                    destinationStationID: "940GZZCRBEK"
                ),
                tramPrediction(
                    stationID: "940GZZCRECR",
                    seconds: 75,
                    destinationName: "Beckenham Junction",
                    destinationStationID: "940GZZCRBEK"
                ),
            ],
            repository: repository,
            previousContext: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )

        let train = try #require(resolution?.train)
        #expect(train.previousStationID == "940GZZCRWCR")
        #expect(train.nextStationID == "940GZZCRWEL")
        #expect(resolution?.context.routeIndex == 5)
    }

    @Test func dlrCountdownBoardPredictionsCollapseIntoIndividualMovingVehicles() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let now = Date(timeIntervalSince1970: 4_000)
        let predictions = [
            dlrPrediction(stationID: "940GZZDLSHA", seconds: 30, destinationStationID: "940GZZDLBNK"),
            dlrPrediction(stationID: "940GZZDLBNK", seconds: 90, destinationStationID: "940GZZDLBNK"),
            dlrPrediction(stationID: "940GZZDLLIM", seconds: 60, destinationStationID: "940GZZDLBNK"),
            dlrPrediction(stationID: "940GZZDLSHA", seconds: 120, destinationStationID: "940GZZDLBNK"),
            dlrPrediction(stationID: "940GZZDLBNK", seconds: 180, destinationStationID: "940GZZDLBNK"),
        ]

        let trains = DLRPredictionResolver.resolve(
            predictions: predictions,
            repository: repository,
            now: now
        )

        #expect(trains.count == 2)
        #expect(trains.allSatisfy { $0.lineID == .dlr })
        #expect(Set(trains.map(\.nextStationID)) == ["940GZZDLSHA", "940GZZDLLIM"])
        #expect(Set(trains.map(\.previousStationID)) == ["940GZZDLLIM", "940GZZDLWFE"])
        #expect(Set(trains.map(\.id)).count == trains.count)
    }

    @Test func dlrResolverSuppressesAnUnidentifiedIncomingBranch() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let trains = DLRPredictionResolver.resolve(
            predictions: [
                dlrPrediction(
                    stationID: "940GZZDLCGT",
                    seconds: 45,
                    destinationStationID: "940GZZDLWLA"
                ),
            ],
            repository: repository,
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(trains.isEmpty)
    }

    @Test func dlrResolverShowsOnlyTheNextTerminalDeparture() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let trains = DLRPredictionResolver.resolve(
            predictions: [
                dlrPrediction(
                    stationID: "940GZZDLTWG",
                    seconds: 40,
                    destinationStationID: "940GZZDLBEC"
                ),
                dlrPrediction(
                    stationID: "940GZZDLTWG",
                    seconds: 340,
                    destinationStationID: "940GZZDLBEC"
                ),
                dlrPrediction(
                    stationID: "940GZZDLSHA",
                    seconds: 100,
                    destinationStationID: "940GZZDLBEC"
                ),
            ],
            repository: repository,
            now: Date(timeIntervalSince1970: 6_000)
        )

        let train = try #require(trains.first)
        #expect(trains.count == 1)
        #expect(train.previousStationID == "940GZZDLTWG")
        #expect(train.nextStationID == "940GZZDLSHA")
        #expect(train.progress == 0.05)
        #expect(train.secondsToNextStation == 100)
    }

    @Test func indexedSegmentLookupMatchesEveryBundledConnectionInBothDirections() throws {
        let graph = try TubeGraph.bundled()
        let repository = TubeNetworkRepository(graph: graph)

        for segment in graph.segments {
            #expect(repository.segment(
                between: segment.fromStationID,
                and: segment.toStationID,
                on: segment.lineID
            )?.id == segment.id)
            #expect(repository.segment(
                between: segment.toStationID,
                and: segment.fromStationID,
                on: segment.lineID
            )?.id == segment.id)
        }
    }

    @Test func cachedRenderPathInterpolatesWithoutRebuildingGeometry() throws {
        let from = TubeStation(
            id: "from",
            name: "From",
            latitude: 51,
            longitude: 0,
            schematicX: 0,
            schematicY: 0,
            lineIDs: [.central],
            interchange: false,
            searchAliases: [],
            hubID: nil
        )
        let to = TubeStation(
            id: "to",
            name: "To",
            latitude: 51,
            longitude: 0.02,
            schematicX: 1,
            schematicY: 0,
            lineIDs: [.central],
            interchange: false,
            searchAliases: [],
            hubID: nil
        )
        let segment = TubeSegment(
            id: "central:from:to",
            lineID: .central,
            fromStationID: from.id,
            toStationID: to.id,
            schematicPoints: [],
            geographicPoints: [
                GeographicPoint(latitude: 51, longitude: 0),
                GeographicPoint(latitude: 51, longitude: 0.01),
                GeographicPoint(latitude: 51, longitude: 0.02),
            ]
        )
        let path = RealWorldRenderPath(
            segment: segment,
            stationsByID: [from.id: from, to.id: to]
        )

        let quarter = try #require(path.coordinate(at: 0.25))
        let reverseQuarter = try #require(path.coordinate(
            at: 0.25,
            previousStationID: to.id,
            nextStationID: from.id
        ))
        #expect(abs(quarter.latitude - 51) < 0.000_001)
        #expect(abs(quarter.longitude - 0.005) < 0.000_001)
        #expect(abs(reverseQuarter.longitude - 0.015) < 0.000_001)
        #expect(path.coordinate(at: -1)?.longitude == from.longitude)
        #expect(path.coordinate(at: 2)?.longitude == to.longitude)
    }

    @Test func realWorldMapBatchesSegmentsIntoStableNonBranchingPolylines() throws {
        let graph = try TubeGraph.bundled()
        let renderData = RealWorldMapRenderData(graph: graph)
        let renderedSegmentIDs = renderData.polylines.flatMap(\.segmentIDs)

        #expect(renderedSegmentIDs.count == graph.segments.count)
        #expect(Set(renderedSegmentIDs) == Set(graph.segments.map(\.id)))
        #expect(renderData.polylines.count < 100)
        #expect(renderData.polylines.allSatisfy { $0.coordinates.count >= 2 })

        let tramSegmentIDs = Set(graph.segments(for: .tram).map(\.id))
        let renderedTramSegmentIDs = Set(renderData.polylines
            .filter { $0.lineID == .tram }
            .flatMap(\.segmentIDs))
        #expect(!tramSegmentIDs.isEmpty)
        #expect(renderedTramSegmentIDs == tramSegmentIDs)

        let affectedSegmentIDs = Set(graph.segments.prefix(75).map(\.id))
        let affectedPolylines = renderData.polylines(covering: affectedSegmentIDs)
        #expect(Set(affectedPolylines.flatMap(\.segmentIDs)) == affectedSegmentIDs)
    }

    @Test func schematicMapBatchesStationArtworkIntoFewDrawOperations() throws {
        let document = try BeckMapRepository().load(
            region: .fullUnderground,
            graph: TubeGraph.bundled()
        )
        let cache = BeckMapCanvas.RenderCache(document: document)
        let unbatchedDrawOperations = document.stationMarkers.reduce(into: 0) { count, marker in
            for primitive in marker.primitives {
                switch primitive {
                case .connector, .circle:
                    count += 2
                case .walkingConnector, .tick:
                    count += 1
                }
            }
        }

        #expect(unbatchedDrawOperations > 900)
        #expect(cache.stationMarkerBatches.normalDrawOperationCount <= 30)
        #expect(cache.stationMarkerBatches.normalDrawOperationCount * 10 < unbatchedDrawOperations)
    }

    @Test func schematicPanCacheRefreshesFarLessOftenThanGestureUpdates() {
        #expect(BeckMapArtworkCachePolicy.rebaseDistance < BeckMapArtworkCachePolicy.overscan)

        var renderOffset = CGSize.zero
        var refreshCount = 0
        let gestureOffsets = stride(from: CGFloat.zero, through: 360, by: 4).map {
            CGSize(width: $0, height: $0 * 0.35)
        }
        for cameraOffset in gestureOffsets where BeckMapArtworkCachePolicy.shouldRebase(
            cameraOffset: cameraOffset,
            renderOffset: renderOffset
        ) {
            refreshCount += 1
            renderOffset = cameraOffset
        }

        #expect(gestureOffsets.count > 90)
        #expect(refreshCount <= 3)
        #expect(refreshCount * 20 < gestureOffsets.count)
    }

    @Test func schematicPinchUsesCachedArtworkBetweenCoverageRebases() {
        let viewportSize = CGSize(width: 430, height: 932)
        let zoomOutScales = Array(stride(from: CGFloat(1), through: 0.2, by: -0.01))

        var renderScale: CGFloat = 1
        var zoomOutRefreshCount = 0
        for cameraScale in zoomOutScales where BeckMapArtworkCachePolicy.shouldRebaseZoom(
            cameraScale: cameraScale,
            renderScale: renderScale,
            viewportSize: viewportSize
        ) {
            zoomOutRefreshCount += 1
            renderScale = cameraScale
        }

        let zoomInRefreshCount = stride(from: CGFloat(1), through: 3.8, by: 0.02).reduce(into: 0) {
            if BeckMapArtworkCachePolicy.shouldRebaseZoom(
                cameraScale: $1,
                renderScale: 1,
                viewportSize: viewportSize
            ) {
                $0 += 1
            }
        }

        #expect(zoomOutScales.count > 75)
        #expect(zoomOutRefreshCount <= 6)
        #expect(zoomOutRefreshCount * 10 < zoomOutScales.count)
        #expect(zoomInRefreshCount == 0)
    }

    @Test func schematicStationLabelsReturnAsSoonAsMomentumBegins() {
        #expect(!BeckMapInteractionOverlayPolicy.showsStationLabels(
            isFingerDown: true,
            isPinching: false
        ))
        #expect(BeckMapInteractionOverlayPolicy.showsStationLabels(
            isFingerDown: false,
            isPinching: false
        ))
        #expect(!BeckMapInteractionOverlayPolicy.showsStationLabels(
            isFingerDown: false,
            isPinching: true
        ))
    }

    @Test func schematicMomentumIsBoundedAndRefreshRateIndependent() throws {
        #expect(BeckMapMomentumPolicy.initialVelocity(from: CGPoint(x: 50, y: 0)) == nil)

        let initialVelocity = try #require(BeckMapMomentumPolicy.initialVelocity(
            from: CGPoint(x: 4_000, y: 1_000)
        ))
        #expect(
            BeckMapMomentumPolicy.projectedDistance(for: initialVelocity)
                <= BeckMapMomentumPolicy.maximumProjectedDistance + 0.001
        )

        func simulatedDistance(framesPerSecond: Int) -> CGSize {
            let frameDuration = 1.0 / Double(framesPerSecond)
            var velocity = initialVelocity
            var distance = CGSize.zero

            for _ in 0..<framesPerSecond {
                let nextVelocity = BeckMapMomentumPolicy.attenuatedVelocity(
                    velocity,
                    over: frameDuration
                )
                let translation = BeckMapMomentumPolicy.translation(
                    from: velocity,
                    to: nextVelocity,
                    over: frameDuration
                )
                distance.width += translation.width
                distance.height += translation.height
                velocity = nextVelocity
            }
            return distance
        }

        let distanceAt60Hz = simulatedDistance(framesPerSecond: 60)
        let distanceAt120Hz = simulatedDistance(framesPerSecond: 120)
        #expect(abs(distanceAt60Hz.width - distanceAt120Hz.width) < 0.05)
        #expect(abs(distanceAt60Hz.height - distanceAt120Hz.height) < 0.05)

        let laterVelocity = BeckMapMomentumPolicy.attenuatedVelocity(
            initialVelocity,
            over: 1.0
        )
        #expect(
            hypot(laterVelocity.x, laterVelocity.y)
                < hypot(initialVelocity.x, initialVelocity.y)
        )
    }
}

private func tramPrediction(
    stationID: String,
    seconds: Int,
    destinationName: String,
    destinationStationID: String? = nil
) -> TfLLiveTrainPrediction {
    TfLLiveTrainPrediction(
        vehicleId: "tram-test-vehicle",
        lineId: TubeLineID.tram.rawValue,
        naptanId: stationID,
        direction: nil,
        destinationName: destinationName,
        destinationNaptanId: destinationStationID,
        towards: destinationName,
        timeToStation: seconds,
        currentLocation: nil,
        platformName: "Westbound"
    )
}

private func dlrPrediction(
    stationID: String,
    seconds: Int,
    destinationStationID: String
) -> TfLLiveTrainPrediction {
    TfLLiveTrainPrediction(
        vehicleId: "",
        lineId: TubeLineID.dlr.rawValue,
        naptanId: stationID,
        direction: "inbound",
        destinationName: "Bank DLR Station",
        destinationNaptanId: destinationStationID,
        towards: "",
        timeToStation: seconds,
        currentLocation: "",
        platformName: "Platform 2"
    )
}
