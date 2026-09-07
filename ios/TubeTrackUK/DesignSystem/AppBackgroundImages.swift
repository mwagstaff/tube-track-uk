import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit

enum AppBackgroundImageCatalog {
    static let bundleDirectoryName = "BackgroundImages"
    static let manifestFilename = "manifest.txt"
    private static let supportedExtensions: Set<String> = [
        "heic", "heif", "jpeg", "jpg", "png", "webp"
    ]

    static func imageURLs(in bundle: Bundle = .main) -> [URL] {
        guard let resourceURL = bundle.resourceURL else { return [] }
        return imageURLs(
            in: resourceURL.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        )
    }

    static func imageURLs(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let manifestURL = directoryURL.appendingPathComponent(manifestFilename)
        guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return []
        }

        let directoryPath = directoryURL.standardizedFileURL.path
        return manifest
            .split(whereSeparator: \Character.isNewline)
            .compactMap { entry -> URL? in
                let relativePath = String(entry)
                guard !relativePath.isEmpty else { return nil }
                let url = directoryURL
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
                guard url.path.hasPrefix(directoryPath + "/"),
                      supportedExtensions.contains(url.pathExtension.lowercased()),
                      fileManager.fileExists(atPath: url.path) else {
                    return nil
                }
                return url
            }
    }
}

enum AppBackgroundImageSelection {
    static func next(
        from imageURLs: [URL],
        excluding currentURL: URL?,
        randomIndex: (Range<Int>) -> Int = { Int.random(in: $0) }
    ) -> URL? {
        let candidates: [URL]
        if imageURLs.count > 1, let currentURL {
            candidates = imageURLs.filter { $0 != currentURL }
        } else {
            candidates = imageURLs
        }
        guard !candidates.isEmpty else { return nil }
        return candidates[randomIndex(candidates.indices)]
    }
}

struct AppBackgroundImageAttribution: Equatable {
    static let unsplashPhotoIDLength = 11

    let artistName: String
    let sourceName: String
    let sourceURL: URL

    init?(imageURL: URL) {
        let filename = imageURL.deletingPathExtension().lastPathComponent
        let sourceSuffix = "-unsplash"
        guard filename.hasSuffix(sourceSuffix) else { return nil }

        let attributionStem = filename.dropLast(sourceSuffix.count)
        let separatorAndIDLength = Self.unsplashPhotoIDLength + 1
        guard attributionStem.count > separatorAndIDLength else { return nil }

        let photoID = String(attributionStem.suffix(Self.unsplashPhotoIDLength))
        let authorAndSeparator = attributionStem.dropLast(Self.unsplashPhotoIDLength)
        guard authorAndSeparator.last == "-",
              photoID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }

        let authorSlug = authorAndSeparator.dropLast()
        let artistName = authorSlug
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        guard !artistName.isEmpty,
              let sourceURL = URL(string: "https://unsplash.com/photos/\(photoID)") else {
            return nil
        }

        self.artistName = artistName
        self.sourceName = "Unsplash"
        self.sourceURL = sourceURL
    }
}

@MainActor
@Observable
final class AppBackgroundImageStore {
    static let rotationInterval: TimeInterval = 60 * 60
    nonisolated private static let maximumImagePixelDimension = 2_560

    private(set) var selectedImageURL: URL?
    private(set) var selectedImage: UIImage?
    private(set) var imageLoadGeneration = 0
    private(set) var mapRevealGeneration = 1

    var selectedImageAttribution: AppBackgroundImageAttribution? {
        selectedImageURL.flatMap(AppBackgroundImageAttribution.init)
    }

    @ObservationIgnored private let imageURLs: [URL]
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private let startsTimer: Bool
    @ObservationIgnored private var selectedAt: Date?
    @ObservationIgnored private var inactiveAt: Date?
    @ObservationIgnored private var consumedMapRevealGeneration = 0
    @ObservationIgnored private var imageLoadTask: Task<Void, Never>?
    @ObservationIgnored private var rotationTask: Task<Void, Never>?

    init(
        imageURLs: [URL] = AppBackgroundImageCatalog.imageURLs(),
        interval: TimeInterval = rotationInterval,
        startsTimer: Bool = true,
        now: Date = Date()
    ) {
        self.imageURLs = imageURLs
        self.interval = interval
        self.startsTimer = startsTimer
        rotate(at: now)
        if startsTimer {
            startRotationTimer()
        }
    }

    @discardableResult
    func appDidBecomeActive(at now: Date = Date()) -> Bool {
        let shouldRevealMapBackground = inactiveAt.map {
            now.timeIntervalSince($0) > interval
        } ?? false
        if shouldRevealMapBackground {
            mapRevealGeneration += 1
        }
        inactiveAt = nil
        if let selectedAt, now.timeIntervalSince(selectedAt) >= interval {
            rotate(at: now)
        }
        if startsTimer, rotationTask == nil || rotationTask?.isCancelled == true {
            startRotationTimer()
        }
        return shouldRevealMapBackground
    }

    func appDidBecomeInactive(at now: Date = Date()) {
        if inactiveAt == nil {
            inactiveAt = now
        }
    }

    func consumeMapReveal() -> Bool {
        guard consumedMapRevealGeneration < mapRevealGeneration else { return false }
        consumedMapRevealGeneration = mapRevealGeneration
        return true
    }

    func rotate(at now: Date = Date()) {
        selectImage(
            AppBackgroundImageSelection.next(
                from: imageURLs,
                excluding: selectedImageURL
            ),
            at: now
        )
    }

    #if DEBUG
    func advanceToNextImage(at now: Date = Date()) {
        guard !imageURLs.isEmpty else { return }
        let nextURL: URL
        if let selectedImageURL,
           let currentIndex = imageURLs.firstIndex(of: selectedImageURL) {
            nextURL = imageURLs[imageURLs.index(after: currentIndex) % imageURLs.count]
        } else {
            nextURL = imageURLs[0]
        }
        selectImage(nextURL, at: now)
    }
    #endif

    private func selectImage(_ imageURL: URL?, at now: Date) {
        selectedImageURL = imageURL
        selectedAt = now
        imageLoadTask?.cancel()
        guard let imageURL else {
            selectedImage = nil
            imageLoadGeneration += 1
            return
        }

        // Even a downsampled photo may require reading and decoding several
        // megabytes. Keep that work out of App initialization and off the main
        // actor so iOS can draw the first frame without waiting for the photo.
        imageLoadTask = Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.loadImage(at: imageURL)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.selectedImageURL == imageURL else { return }
            self.selectedImage = image
            self.imageLoadGeneration += 1
            self.imageLoadTask = nil
        }
    }

    nonisolated private static func loadImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumImagePixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private func startRotationTimer() {
        rotationTask?.cancel()
        rotationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                rotate()
            }
        }
    }
}

enum AppBackgroundImagePlaceholder {
    case systemBackground
    case launch
}

struct AppBackgroundImage: View {
    @Environment(AppBackgroundImageStore.self) private var store

    var scrimOpacity: Double = 0
    var placeholder: AppBackgroundImagePlaceholder = .systemBackground

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholderView

                if let image = store.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    Color.black.opacity(scrimOpacity)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var placeholderView: some View {
        switch placeholder {
        case .systemBackground:
            Color(.systemBackground)
        case .launch:
            ZStack {
                Color("LaunchBackground")

                Image("LaunchMark")
            }
        }
    }
}

private struct AppBackgroundPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                AppBackgroundImage(scrimOpacity: 0.34)
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    func appBackgroundPage() -> some View {
        modifier(AppBackgroundPageModifier())
    }
}

struct AppBackgroundSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
    }
}
