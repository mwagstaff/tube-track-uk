import Combine
import CoreMotion
import QuartzCore
import SwiftUI
import UIKit

struct AppBackgroundParallaxFilter {
    static let maximumHorizontalTranslation: CGFloat = 34
    static let maximumVerticalTranslation: CGFloat = 28

    private static let maximumAngle = 0.18
    private static let deadZone = 0.006
    private static let dampingTimeConstant = 0.14

    private(set) var translation = CGSize.zero
    private var lastTimestamp: TimeInterval?

    init(translation: CGSize = .zero) {
        self.translation = translation
    }

    mutating func update(
        horizontalAngle: Double,
        verticalAngle: Double,
        timestamp: TimeInterval
    ) -> CGSize {
        let target = CGSize(
            width: -normalized(horizontalAngle) * Self.maximumHorizontalTranslation,
            height: -normalized(verticalAngle) * Self.maximumVerticalTranslation
        )
        let elapsed = lastTimestamp.map {
            min(max(timestamp - $0, 1.0 / 240.0), 0.1)
        } ?? 1.0 / 60.0
        let response = 1 - exp(-elapsed / Self.dampingTimeConstant)
        translation.width += (target.width - translation.width) * response
        translation.height += (target.height - translation.height) * response
        lastTimestamp = timestamp
        return translation
    }

    private func normalized(_ angle: Double) -> CGFloat {
        let magnitude = abs(angle)
        guard magnitude > Self.deadZone else { return 0 }
        let adjusted = min(
            (magnitude - Self.deadZone) / (Self.maximumAngle - Self.deadZone),
            1
        )
        return CGFloat(angle.sign == .minus ? -adjusted : adjusted)
    }
}

enum AppBackgroundScreenOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            self = .portrait
        }
    }
}

struct AppBackgroundAttitudeProjection {
    static func screenAngles(
        quaternion: CMQuaternion,
        orientation: AppBackgroundScreenOrientation
    ) -> (horizontal: Double, vertical: Double) {
        let sign = quaternion.w < 0 ? -1.0 : 1.0
        let x = quaternion.x * sign
        let y = quaternion.y * sign
        let z = quaternion.z * sign
        let w = quaternion.w * sign
        let vectorMagnitude = sqrt((x * x) + (y * y) + (z * z))
        let angleScale = vectorMagnitude > 1e-8
            ? 2 * atan2(vectorMagnitude, w) / vectorMagnitude
            : 2
        let rotationX = x * angleScale
        let rotationY = y * angleScale

        switch orientation {
        case .portrait:
            return (rotationY, rotationX)
        case .portraitUpsideDown:
            return (-rotationY, -rotationX)
        case .landscapeLeft:
            return (-rotationX, rotationY)
        case .landscapeRight:
            return (rotationX, -rotationY)
        }
    }
}

struct AppBackgroundPhotoGeometry {
    let renderedSize: CGSize
    private let viewportSize: CGSize

    init(
        viewportSize: CGSize,
        sourceSize: CGSize,
        parallaxScale: CGFloat
    ) {
        self.viewportSize = viewportSize
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)
        let fillScale = max(
            viewportSize.width / sourceWidth,
            viewportSize.height / sourceHeight
        )
        let renderScale = fillScale * max(parallaxScale, 1)
        renderedSize = CGSize(
            width: sourceWidth * renderScale,
            height: sourceHeight * renderScale
        )
    }

    func boundedTranslation(_ requested: CGSize) -> CGSize {
        CGSize(
            width: Self.boundedTranslation(
                requested.width,
                viewportLength: viewportSize.width,
                renderedLength: renderedSize.width
            ),
            height: Self.boundedTranslation(
                requested.height,
                viewportLength: viewportSize.height,
                renderedLength: renderedSize.height
            )
        )
    }

    private static func boundedTranslation(
        _ requested: CGFloat,
        viewportLength: CGFloat,
        renderedLength: CGFloat
    ) -> CGFloat {
        let maximum = max((renderedLength - viewportLength) / 2, 0)
        return min(max(requested, -maximum), maximum)
    }
}

private final class AppBackgroundMotionProcessor {
    private let orientation: AppBackgroundScreenOrientation
    private var referenceAttitude: CMAttitude?
    private var filter: AppBackgroundParallaxFilter

    init(orientation: UIInterfaceOrientation, initialTranslation: CGSize) {
        self.orientation = AppBackgroundScreenOrientation(orientation)
        filter = AppBackgroundParallaxFilter(translation: initialTranslation)
    }

    func translation(for motion: CMDeviceMotion) -> CGSize? {
        guard let relativeAttitude = motion.attitude.copy() as? CMAttitude else {
            return nil
        }
        if referenceAttitude == nil {
            referenceAttitude = motion.attitude.copy() as? CMAttitude
        }
        guard let referenceAttitude else { return nil }
        relativeAttitude.multiply(byInverseOf: referenceAttitude)

        let angles = AppBackgroundAttitudeProjection.screenAngles(
            quaternion: relativeAttitude.quaternion,
            orientation: orientation
        )
        return filter.update(
            horizontalAngle: angles.horizontal,
            verticalAngle: angles.vertical,
            timestamp: motion.timestamp
        )
    }
}

@MainActor
final class AppBackgroundMotionModel: NSObject, ObservableObject {
    static let shared = AppBackgroundMotionModel()

    @Published private(set) var translation = CGSize.zero

    private let motionManager = CMMotionManager()
    private var activeViews: Set<UUID> = []
    private var orientation: UIInterfaceOrientation = .portrait
    private var motionProcessor: AppBackgroundMotionProcessor?
    private var displayLink: CADisplayLink?

    private override init() {
        super.init()
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
    }

    func activate(viewID: UUID, orientation: UIInterfaceOrientation) {
        let wasInactive = activeViews.isEmpty
        activeViews.insert(viewID)
        if self.orientation != orientation {
            self.orientation = orientation
            if !wasInactive {
                restartUpdates()
                return
            }
        }
        if wasInactive {
            startUpdates()
        }
    }

    func deactivate(viewID: UUID) {
        activeViews.remove(viewID)
        guard activeViews.isEmpty else { return }
        stopUpdates()
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard self.orientation != orientation else { return }
        self.orientation = orientation
        guard !activeViews.isEmpty else { return }
        restartUpdates()
    }

    private func restartUpdates() {
        stopUpdates(centresImage: false)
        startUpdates()
    }

    private func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            #if DEBUG
            print("[TubeTrack] background parallax unavailable: device motion is unavailable")
            #endif
            return
        }
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        guard availableFrames.contains(.xArbitraryZVertical) else {
            #if DEBUG
            print("[TubeTrack] background parallax unavailable: reference frame is unavailable")
            #endif
            return
        }

        motionProcessor = AppBackgroundMotionProcessor(
            orientation: orientation,
            initialTranslation: translation
        )
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(sampleLatestMotion)
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 20,
            maximum: 30,
            preferred: 30
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        #if DEBUG
        print("[TubeTrack] background parallax started at up to 30 fps")
        #endif
    }

    private func stopUpdates(centresImage: Bool = true) {
        displayLink?.invalidate()
        displayLink = nil
        motionManager.stopDeviceMotionUpdates()
        motionProcessor = nil
        guard centresImage else { return }
        withAnimation(.easeOut(duration: 0.45)) {
            translation = .zero
        }
    }

    @objc private func sampleLatestMotion() {
        guard let motion = motionManager.deviceMotion,
              let nextTranslation = motionProcessor?.translation(for: motion),
              shouldPublish(nextTranslation) else {
            return
        }
        translation = nextTranslation
    }

    private func shouldPublish(_ nextTranslation: CGSize) -> Bool {
        abs(nextTranslation.width - translation.width) >= 0.05
            || abs(nextTranslation.height - translation.height) >= 0.05
    }
}

@MainActor
private struct AppBackgroundMotionLifecycleModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var viewID = UUID()

    private var motion: AppBackgroundMotionModel {
        .shared
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateMotionActivity()
            }
            .onDisappear {
                isVisible = false
                updateMotionActivity()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateMotionActivity()
            }
            .onChange(of: scenePhase) { _, _ in
                updateMotionActivity()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification
            )) { _ in
                guard motionIsEnabled else { return }
                motion.updateOrientation(currentInterfaceOrientation)
            }
    }

    private var motionIsEnabled: Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .effectiveGeometry.interfaceOrientation ?? .portrait
    }

    private func updateMotionActivity() {
        if motionIsEnabled {
            motion.activate(viewID: viewID, orientation: currentInterfaceOrientation)
        } else {
            motion.deactivate(viewID: viewID)
        }
    }
}

private extension View {
    func appBackgroundMotionLifecycle() -> some View {
        modifier(AppBackgroundMotionLifecycleModifier())
    }
}

struct AppBackgroundImageViewer: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = AppBackgroundMotionModel.shared

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            AppBackgroundViewerPhoto(
                image: backgroundImageStore.selectedImage,
                parallaxScale: reduceMotion ? 1 : 1.18,
                parallaxTranslation: reduceMotion ? .zero : motion.translation
            )

            controls
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
        .preferredColorScheme(.dark)
        .appBackgroundMotionLifecycle()
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: dismissToMap) {
                    Image(systemName: "xmark")
                        .font(.appCaption(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.5), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close photo")
                .accessibilityHint("Returns to the map")
            }

            Spacer(minLength: 24)

            if let attribution = backgroundImageStore.selectedImageAttribution {
                Link(destination: attribution.sourceURL) {
                    HStack(spacing: 5) {
                        Text("Image courtesy of \(attribution.artistName), \(attribution.sourceName)")
                            .multilineTextAlignment(.center)
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityHidden(true)
                    }
                    .font(.appCaption2(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())
                }
                .requiresNetwork(
                    appState.isOffline,
                    onlineHint: "Opens this photograph on Unsplash in your browser"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard AppBackgroundViewerDismissGesture.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) else { return }
                dismissToMap()
            }
    }

    private func dismissToMap() {
        appState.selectedTab = .map
        dismiss()
    }
}

private struct AppBackgroundViewerPhoto: View {
    let image: UIImage?
    let parallaxScale: CGFloat
    let parallaxTranslation: CGSize

    var body: some View {
        GeometryReader { proxy in
            if let image {
                let geometry = AppBackgroundPhotoGeometry(
                    viewportSize: proxy.size,
                    sourceSize: image.size,
                    parallaxScale: parallaxScale
                )
                let translation = geometry.boundedTranslation(parallaxTranslation)

                Image(uiImage: image)
                    .resizable()
                    .frame(
                        width: geometry.renderedSize.width,
                        height: geometry.renderedSize.height
                    )
                    .offset(x: translation.width, y: translation.height)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .accessibilityLabel("Background photograph")
                    .accessibilityHint("Tilt your phone to adjust the image view, or swipe down to close")
            }
        }
        .ignoresSafeArea()
    }
}

enum AppBackgroundViewerDismissGesture {
    private static let directionalDominance: CGFloat = 1.15
    private static let commitDistance: CGFloat = 44
    private static let projectedCommitDistance: CGFloat = 90

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        guard translation.height > 0,
              abs(translation.height) > abs(translation.width) * directionalDominance else {
            return false
        }
        let projectionContinuesDownward = predictedEndTranslation.height > 0
        return translation.height >= commitDistance || (
            projectionContinuesDownward
                && predictedEndTranslation.height >= projectedCommitDistance
        )
    }
}
