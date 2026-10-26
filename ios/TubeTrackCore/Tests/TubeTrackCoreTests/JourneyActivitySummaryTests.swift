import Foundation
import Testing
@testable import TubeTrackCore

struct JourneyActivitySummaryTests {
    @Test func previousActivitiesDecodeWithoutOrigin() throws {
        let data = Data(#"{"sessionID":"old","destination":"Stratford DLR Station","endsAtEpoch":123}"#.utf8)
        let attributes = try JSONDecoder().decode(JourneyActivityAttributes.self, from: data)
        #expect(attributes.origin == nil)
        #expect(attributes.summary(for: state) == "Elverson Road → Stratford")
    }
    @Test func summaryKeepsTheWholeRouteAfterBoarding() {
        let attributes = JourneyActivityAttributes(sessionID: "trip", destination: "Stratford DLR Station",
            endsAtEpoch: 123, origin: "Clock House Rail Station")
        var onboard = state
        onboard.headline = "Towards Canary Wharf DLR Station"
        onboard.phase = "onboard"
        #expect(attributes.summary(for: onboard) == "Clock House → Stratford")
        #expect(JourneyActivityAttributes.shortStationName("Battersea Power Station") == "Battersea Power Station")
    }
    private var state: JourneyActivityAttributes.ContentState {
        .init(phase: "waiting", legIndex: 0, headline: "Board at Elverson Road DLR Station",
              nextStop: "Canary Wharf DLR Station", destination: "Stratford DLR Station",
              nextArrivalEpoch: nil, finalArrivalEpoch: nil, boardTitle: nil, departures: [],
              updatedAtEpoch: 0, staleAtEpoch: 90, message: "", sequence: 0)
    }
}
