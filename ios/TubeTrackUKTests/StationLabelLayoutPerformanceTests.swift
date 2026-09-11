import Foundation
import Testing
@testable import TubeTrackUK

struct StationLabelLayoutPerformanceTests {
    @Test func orderedSearchPreservesExhaustivePlacementAcrossDenseMapViews() {
        for scale: CGFloat in [0.65, 1, 1.6] {
            for offset in [CGPoint.zero, CGPoint(x: -71, y: 93), CGPoint(x: 118, y: -47)] {
                let scene = makeScene(scale: scale, offset: offset)
                let expected = exhaustiveLayout(
                    inputs: scene.inputs,
                    viewport: scene.viewport,
                    markers: scene.markers,
                    lines: scene.lines
                )
                let actual = StationLabelLayoutEngine.layout(
                    inputs: scene.inputs,
                    viewport: scene.viewport,
                    markerBlockers: scene.markers,
                    lineBlockers: scene.lines
                )

                #expect(!expected.isEmpty)
                #expect(actual.count == expected.count)
                for (actual, expected) in zip(actual, expected) {
                    #expect(actual.labelID == expected.labelID)
                    #expect(actual.position == expected.position)
                    #expect(actual.alignment == expected.alignment)
                    #expect(actual.rotation == expected.rotation)
                    #expect(actual.backgroundBounds == expected.backgroundBounds)
                    #expect(actual.collisionFrame == expected.collisionFrame)
                }
            }
        }
    }

    @Test func candidateOrderingMatchesTheOriginalPreferenceScores() {
        for alignment in [BeckMapLabelAlignment.leading, .centre, .trailing] {
            for offset in [CGVector(dx: 25, dy: -15), CGVector(dx: -25, dy: 15)] {
                let options = BeckMapLabelPlacementResolver.placementOptions(
                    authoredAlignment: alignment,
                    screenOffset: offset
                )
                var previousScore = -1
                for (optionIndex, option) in options.enumerated() {
                    let candidates = BeckMapLabelPlacementResolver.candidates(
                        stationScreenPosition: CGPoint(x: 200, y: 200),
                        markerFrame: CGRect(x: 194, y: 194, width: 12, height: 12),
                        labelBounds: CGRect(x: -30, y: -8, width: 60, height: 16),
                        screenOffset: option.screenOffset,
                        authoredAlignment: option.alignment
                    )
                    for candidateIndex in candidates.indices {
                        let score = optionIndex * 18 + candidateIndex
                        #expect(score > previousScore)
                        previousScore = score
                    }
                }
            }
        }
    }

    private struct Scene {
        let inputs: [StationLabelLayoutInput]
        let viewport: CGRect
        let markers: [BeckMapLabelBlocker]
        let lines: [BeckMapLineBlocker]
    }

    private func makeScene(scale: CGFloat, offset: CGPoint) -> Scene {
        let viewport = CGRect(x: 8, y: 40, width: 704, height: 840)
        let alignments: [BeckMapLabelAlignment] = [.leading, .centre, .trailing]
        let tiers: [BeckMapLabelVisibilityTier] = [.overview, .network, .local, .minor]
        var inputs: [StationLabelLayoutInput] = []
        var markers: [BeckMapLabelBlocker] = []
        var lines: [BeckMapLineBlocker] = []

        for index in 0..<144 {
            let position = CGPoint(
                x: CGFloat(index % 12) * 74 * scale + offset.x,
                y: CGFloat(index / 12) * 76 * scale + offset.y
            )
            let marker = CGRect(x: position.x - 6, y: position.y - 6, width: 12, height: 12)
            markers.append(BeckMapLabelBlocker(stationID: "station-\(index)", frame: marker))
            if index % 3 == 0 {
                lines.append(BeckMapLineBlocker(
                    start: CGPoint(x: position.x - 54, y: position.y + 23),
                    end: CGPoint(x: position.x + 54, y: position.y + 23),
                    clearance: 5
                ))
            }
            let bounds = Dictionary(uniqueKeysWithValues: alignments.map { alignment in
                (alignment, BeckMapLabelBounds.backgroundBounds(
                    textSize: CGSize(width: CGFloat(36 + index % 8 * 11) * scale, height: 15 * scale),
                    alignment: alignment,
                    horizontalPadding: 3,
                    verticalPadding: 2
                ))
            })
            inputs.append(StationLabelLayoutInput(
                id: "label-\(index)",
                priority: index % 7,
                tier: tiers[index % tiers.count],
                selected: index == 67,
                stationScreenPosition: position,
                markerFrame: marker,
                preferredAlignment: alignments[index % alignments.count],
                screenOffset: CGVector(dx: index % 2 == 0 ? 18 : -18, dy: index % 4 < 2 ? -12 : 12),
                rotation: CGAffineTransform(rotationAngle: index % 5 == 0 ? -.pi / 4 : 0),
                boundsByAlignment: bounds
            ))
        }
        return Scene(inputs: inputs.reversed(), viewport: viewport, markers: markers, lines: lines)
    }

    // Preserve the previous exhaustive scoring algorithm as an independent
    // reference. Array collision checks also verify the production spatial index.
    private func exhaustiveLayout(
        inputs: [StationLabelLayoutInput],
        viewport: CGRect,
        markers: [BeckMapLabelBlocker],
        lines: [BeckMapLineBlocker]
    ) -> [StationLabelPlacement] {
        let ordered = inputs.sorted { lhs, rhs in
            if lhs.selected != rhs.selected { return lhs.selected }
            if lhs.tier != rhs.tier { return lhs.tier.renderPriority > rhs.tier.renderPriority }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
        var placements: [StationLabelPlacement] = []
        var occupied: [CGRect] = []

        for input in ordered {
            let options = BeckMapLabelPlacementResolver.placementOptions(
                authoredAlignment: input.preferredAlignment,
                screenOffset: input.screenOffset
            )
            var best: (score: Int, placement: StationLabelPlacement)?
            for (optionIndex, option) in options.enumerated() {
                guard let bounds = input.boundsByAlignment[option.alignment] else { continue }
                let candidates = BeckMapLabelPlacementResolver.candidates(
                    stationScreenPosition: input.stationScreenPosition,
                    markerFrame: input.markerFrame,
                    labelBounds: bounds,
                    screenOffset: option.screenOffset,
                    authoredAlignment: option.alignment
                )
                for (candidateIndex, candidate) in candidates.enumerated() {
                    let frame = bounds.applying(input.rotation).standardized
                        .offsetBy(dx: candidate.position.x, dy: candidate.position.y)
                    guard viewport.contains(frame) else { continue }
                    let collisionFrame = frame.insetBy(
                        dx: -StationLabelLayoutEngine.horizontalLabelClearance,
                        dy: -StationLabelLayoutEngine.verticalLabelClearance
                    )
                    guard BeckMapLabelCollisionResolver.accepts(
                        collisionFrame,
                        markerBlockers: markers,
                        lineBlockers: lines,
                        occupied: occupied
                    ) else { continue }
                    let score = optionIndex * 18 + candidateIndex
                    if best == nil || score < best!.score {
                        best = (score, StationLabelPlacement(
                            labelID: input.id,
                            position: candidate.position,
                            alignment: candidate.alignment,
                            rotation: input.rotation,
                            backgroundBounds: bounds,
                            collisionFrame: collisionFrame
                        ))
                    }
                }
            }
            if let placement = best?.placement {
                placements.append(placement)
                occupied.append(placement.collisionFrame)
            }
        }
        return placements
    }
}
