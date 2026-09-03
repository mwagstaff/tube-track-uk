import Foundation
import Testing
@testable import TubeTrackUK

struct AppBackgroundImageTests {
    @Test func manifestOnlyReturnsExistingSupportedImagesInsideDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let first = root.appendingPathComponent("first.jpg")
        let second = nested.appendingPathComponent("second.PNG")
        try Data([0x01]).write(to: first)
        try Data([0x02]).write(to: second)
        try "first.jpg\nnested/second.PNG\nmissing.jpeg\n../outside.jpg\nnotes.txt\n"
            .write(
                to: root.appendingPathComponent(AppBackgroundImageCatalog.manifestFilename),
                atomically: true,
                encoding: .utf8
            )

        #expect(AppBackgroundImageCatalog.imageURLs(in: root) == [first, second])
    }

    @Test func rotationAvoidsImmediatelyRepeatingAnImage() {
        let first = URL(fileURLWithPath: "/first.jpg")
        let second = URL(fileURLWithPath: "/second.jpg")

        let selected = AppBackgroundImageSelection.next(
            from: [first, second],
            excluding: first,
            randomIndex: { $0.lowerBound }
        )

        #expect(selected == second)
    }

    @Test func attributionExtractsArtistAndUnsplashPhotoLink() throws {
        let imageURL = URL(
            fileURLWithPath: "/BackgroundImages/diane-picchiottino-sKsNVoa_NsY-unsplash.jpg"
        )

        let attribution = try #require(AppBackgroundImageAttribution(imageURL: imageURL))

        #expect(attribution.artistName == "Diane Picchiottino")
        #expect(attribution.sourceName == "Unsplash")
        #expect(attribution.sourceURL.absoluteString == "https://unsplash.com/photos/sKsNVoa_NsY")
    }

    @Test func attributionHandlesPhotoIDsBeginningWithAHyphen() throws {
        let imageURL = URL(
            fileURLWithPath: "/BackgroundImages/oslo-knappett--fqGFbtB0GU-unsplash.jpg"
        )

        let attribution = try #require(AppBackgroundImageAttribution(imageURL: imageURL))

        #expect(attribution.artistName == "Oslo Knappett")
        #expect(attribution.sourceURL.absoluteString == "https://unsplash.com/photos/-fqGFbtB0GU")
    }

    @Test func attributionRejectsUnsupportedFilenames() {
        let imageURL = URL(fileURLWithPath: "/BackgroundImages/personal-photo.jpg")

        #expect(AppBackgroundImageAttribution(imageURL: imageURL) == nil)
    }

    @Test func viewerDismissesForACommittedDownwardSwipe() {
        #expect(AppBackgroundViewerDismissGesture.shouldDismiss(
            translation: CGSize(width: 8, height: 48),
            predictedEndTranslation: CGSize(width: 10, height: 72)
        ))
        #expect(AppBackgroundViewerDismissGesture.shouldDismiss(
            translation: CGSize(width: 5, height: 24),
            predictedEndTranslation: CGSize(width: 8, height: 110)
        ))
    }

    @Test func viewerDoesNotDismissForUpwardOrHorizontalSwipes() {
        #expect(!AppBackgroundViewerDismissGesture.shouldDismiss(
            translation: CGSize(width: 4, height: -80),
            predictedEndTranslation: CGSize(width: 5, height: -140)
        ))
        #expect(!AppBackgroundViewerDismissGesture.shouldDismiss(
            translation: CGSize(width: 90, height: 50),
            predictedEndTranslation: CGSize(width: 140, height: 100)
        ))
    }

    @Test func parallaxFilterDampsAndBoundsTranslation() {
        var filter = AppBackgroundParallaxFilter()
        var translation = CGSize.zero

        for frame in 1...180 {
            translation = filter.update(
                horizontalAngle: 1,
                verticalAngle: -1,
                timestamp: Double(frame) / 60
            )
        }

        #expect(translation.width < 0)
        #expect(translation.height > 0)
        #expect(abs(translation.width) <= AppBackgroundParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(translation.height) <= AppBackgroundParallaxFilter.maximumVerticalTranslation)
    }

    @Test func parallaxFilterMakesAModestTiltClearlyVisible() {
        var filter = AppBackgroundParallaxFilter()
        var translation = CGSize.zero

        for frame in 1...60 {
            translation = filter.update(
                horizontalAngle: 0.09,
                verticalAngle: 0,
                timestamp: Double(frame) / 30
            )
        }

        #expect(abs(translation.width) >= 15)
        #expect(abs(translation.height) < 0.01)
    }

    @Test func parallaxCropPreservesEdgeToEdgeImageCoverage() {
        let viewport = CGSize(width: 400, height: 800)
        let geometry = AppBackgroundPhotoGeometry(
            viewportSize: viewport,
            sourceSize: CGSize(width: 1_600, height: 900),
            parallaxScale: 1.10
        )
        let translation = geometry.boundedTranslation(
            CGSize(width: 10_000, height: 10_000)
        )

        #expect(geometry.renderedSize.width >= viewport.width)
        #expect(geometry.renderedSize.height >= viewport.height)
        #expect(abs(translation.width) <= (geometry.renderedSize.width - viewport.width) / 2)
        #expect(abs(translation.height) <= (geometry.renderedSize.height - viewport.height) / 2)
    }

    #if DEBUG
    @MainActor
    @Test func debugAdvanceSelectsTheNextManifestImageAndWraps() {
        let first = URL(fileURLWithPath: "/first.jpg")
        let second = URL(fileURLWithPath: "/second.jpg")
        let store = AppBackgroundImageStore(
            imageURLs: [first, second],
            startsTimer: false
        )

        let initialURL = store.selectedImageURL
        store.advanceToNextImage()
        #expect(store.selectedImageURL != initialURL)
        store.advanceToNextImage()
        #expect(store.selectedImageURL == initialURL)
    }
    #endif

    @MainActor
    @Test func mapRevealOccursOnFirstLoadAndAfterMoreThanOneHourInactive() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = AppBackgroundImageStore(
            imageURLs: [],
            startsTimer: false,
            now: start
        )

        #expect(store.consumeMapReveal())
        #expect(!store.consumeMapReveal())

        store.appDidBecomeInactive(at: start)
        #expect(!store.appDidBecomeActive(at: start.addingTimeInterval(3_599)))
        #expect(!store.consumeMapReveal())

        store.appDidBecomeInactive(at: start.addingTimeInterval(4_000))
        #expect(!store.appDidBecomeActive(at: start.addingTimeInterval(7_600)))
        #expect(!store.consumeMapReveal())

        store.appDidBecomeInactive(at: start.addingTimeInterval(8_000))
        #expect(store.appDidBecomeActive(at: start.addingTimeInterval(11_601)))
        #expect(store.consumeMapReveal())
        #expect(!store.consumeMapReveal())

        store.appDidBecomeActive(at: start.addingTimeInterval(12_000))
        #expect(!store.consumeMapReveal())
    }
}
