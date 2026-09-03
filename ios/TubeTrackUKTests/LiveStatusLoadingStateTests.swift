import Foundation
import Testing
@testable import TubeTrackUK

struct LiveStatusLoadingStateTests {
    @Test @MainActor func initialStatusRemainsLoadingUntilTfLResponds() {
        let appState = TubeAppState()

        #expect(appState.isLoadingInitialStatus)

        appState.statusError = "TfL is unavailable"
        #expect(!appState.isLoadingInitialStatus)

        appState.isRefreshingStatus = true
        #expect(appState.isLoadingInitialStatus)

        appState.statusUpdatedAt = .now
        #expect(!appState.isLoadingInitialStatus)
    }
}
