import Testing
import UIKit
@testable import TubeTrackUK

struct AppTypographyTests {
    @Test @MainActor func bundledFontsAreAvailableByPostScriptName() {
        AppTypography.prepare()

        let fontNames = [
            "Cabin-Regular",
            "Cabin-Medium",
            "Cabin-SemiBold",
            "Cabin-Bold",
            "MetropolitanLine-Regular",
        ]

        for fontName in fontNames {
            #expect(UIFont(name: fontName, size: 17) != nil)
        }
    }
}
