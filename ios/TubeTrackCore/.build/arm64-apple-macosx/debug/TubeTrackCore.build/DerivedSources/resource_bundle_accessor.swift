import Foundation

extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("TubeTrackCore_TubeTrackCore.bundle").path
        let buildPath = "/Users/mwagstaff/dev/tube-track-uk/ios/TubeTrackCore/.build/arm64-apple-macosx/debug/TubeTrackCore_TubeTrackCore.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}