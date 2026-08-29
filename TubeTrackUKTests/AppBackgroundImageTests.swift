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
    @Test func mapRevealOccursOncePerAppForegroundSession() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = AppBackgroundImageStore(
            imageURLs: [],
            startsTimer: false,
            now: start
        )

        #expect(store.consumeMapReveal())
        #expect(!store.consumeMapReveal())

        store.appDidBecomeInactive(at: start)
        store.appDidBecomeActive(at: start.addingTimeInterval(1))
        #expect(store.consumeMapReveal())
        #expect(!store.consumeMapReveal())

        store.appDidBecomeActive(at: start.addingTimeInterval(2))
        #expect(!store.consumeMapReveal())
    }
}
