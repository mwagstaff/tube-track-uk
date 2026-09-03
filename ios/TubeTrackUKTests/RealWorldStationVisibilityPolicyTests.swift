import Testing
@testable import TubeTrackUK

struct RealWorldStationVisibilityPolicyTests {
    @Test func initialSwitchedViewportHidesStationRoundelsAndNames() {
        // Captured from the fitted Beck-to-real-world switch on an iPhone.
        let initialSwitchedViewportZoom = 4.12

        #expect(!RealWorldStationVisibilityPolicy.showsRoundel(at: initialSwitchedViewportZoom))
        #expect(!RealWorldStationVisibilityPolicy.showsName(at: initialSwitchedViewportZoom))
    }

    @Test func roundelsAppearBeforeStationNames() {
        let zoom = RealWorldStationVisibilityPolicy.roundelMinimumZoom

        #expect(RealWorldStationVisibilityPolicy.showsRoundel(at: zoom))
        #expect(!RealWorldStationVisibilityPolicy.showsName(at: zoom))
        #expect(
            RealWorldStationVisibilityPolicy.nameMinimumZoom
                > RealWorldStationVisibilityPolicy.roundelMinimumZoom
        )
    }

    @Test func localViewShowsRoundelsAndNames() {
        let zoom = RealWorldStationVisibilityPolicy.nameMinimumZoom

        #expect(RealWorldStationVisibilityPolicy.showsRoundel(at: zoom))
        #expect(RealWorldStationVisibilityPolicy.showsName(at: zoom))
    }

    @Test func selectedStationRemainsVisibleAtOverviewZoom() {
        #expect(RealWorldStationVisibilityPolicy.showsRoundel(at: 0, isSelected: true))
        #expect(RealWorldStationVisibilityPolicy.showsName(at: 0, isSelected: true))
    }
}
