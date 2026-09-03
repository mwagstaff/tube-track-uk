import SwiftUI
import UIKit

struct TubeGameScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let graph: TubeGraph

    @State private var engine: TubeGameEngine?
    @State private var renderModel: TubeGameRenderModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let engine, let renderModel {
                TubeGameSessionView(
                    engine: engine,
                    renderModel: renderModel,
                    onDismiss: { dismiss() }
                )
            } else if let loadError {
                TubeGameLoadFailureView(
                    message: loadError,
                    onDismiss: { dismiss() },
                    onRetry: loadGame
                )
            } else {
                TubeGameLoadingView(onDismiss: { dismiss() })
            }
        }
        .background(Color(.systemBackground))
        .statusBarHidden()
        .task {
            guard engine == nil, loadError == nil else { return }
            loadGame()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            engine?.pause()
        }
    }

    @MainActor
    private func loadGame() {
        loadError = nil
        do {
            let document = try BeckMapRepository().load(
                region: .fullUnderground,
                graph: graph
            )
            let network = try TubeGameNetwork(graph: graph, document: document)
            let nextEngine = try TubeGameEngine(
                network: network,
                seed: UInt64.random(in: UInt64.min ... UInt64.max)
            )
            renderModel = TubeGameRenderModel(document: document, network: network)
            engine = nextEngine
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct TubeGameSessionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(TubeGameHighScoreStore.self) private var highScores

    @Bindable var engine: TubeGameEngine
    let renderModel: TubeGameRenderModel
    let onDismiss: () -> Void

    @State private var submittedRecord: TubeGameScoreRecord?
    @State private var isNewBest = false
    @State private var lastTickDate: Date?
    @State private var directionFeedback = UISelectionFeedbackGenerator()
    @State private var stationFeedback = UIImpactFeedbackGenerator(style: .soft)
    @State private var stationFeedbackTask: Task<Void, Never>?
#if DEBUG
    @State private var debugTimeScale: TimeInterval = 1
    @State private var debugPlaybackIsPaused = false
#endif

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: !timelineIsActive
            )
        ) { timeline in
            GeometryReader { proxy in
                let snapshot = engine.snapshot
                let camera = TubeGameCameraState.following(
                    player: snapshot.player.position,
                    artworkSize: renderModel.artworkSize,
                    viewportSize: proxy.size
                )

                ZStack {
                    TubeGamePlayfield(
                        model: renderModel,
                        snapshot: snapshot,
                        onDirection: queue
                    )
                    .ignoresSafeArea()
                    .accessibilityHidden(!gameplayIsAccessible(snapshot.phase))

                    if snapshot.phase.isRunInProgress {
                        gameChrome(
                            snapshot: snapshot,
                            camera: camera,
                            size: proxy.size
                        )
                        .accessibilityHidden(snapshot.phase == .paused)
                    }

                    phaseOverlay(snapshot: snapshot, size: proxy.size)

#if DEBUG
                    if debugControlsAreVisible(for: snapshot.phase) {
                        debugPlaybackControls
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, 14)
                            .padding(.bottom, max(14, TubeGameWindowMetrics.safeAreaInsets.bottom + 8))
                    }
#endif
                }
                .onChange(of: timeline.date) { _, newDate in
                    let previousDate = lastTickDate ?? newDate
                    lastTickDate = newDate
                    let delta = max(0, newDate.timeIntervalSince(previousDate))
#if DEBUG
                    let gameplayDelta = TubeGameDebugPlayback.scaledDelta(
                        delta,
                        timeScale: debugTimeScale,
                        isPaused: debugPlaybackIsPaused
                    )
                    guard gameplayDelta > 0 else { return }
                    engine.tick(deltaTime: gameplayDelta)
#else
                    engine.tick(deltaTime: delta)
#endif
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: engine.snapshot.phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: engine.snapshot.lastScoreEvent) { _, scoreEvent in
            guard scoreEvent != nil else { return }
            playStationConsumptionFeedback()
        }
        .onAppear {
            directionFeedback.prepare()
            stationFeedback.prepare()
        }
        .onDisappear {
            stationFeedbackTask?.cancel()
        }
    }

    private var timelineIsActive: Bool {
#if DEBUG
        if debugPlaybackIsPaused { return false }
#endif
        return switch engine.snapshot.phase {
        case .countdown, .playing:
            true
        case .ready, .paused, .ended:
            false
        }
    }

#if DEBUG
    private var debugPlaybackControls: some View {
        HStack(spacing: 8) {
            Text("DEBUG")
                .font(.appCaption2(.bold))
                .foregroundStyle(.secondary)

            Button {
                debugTimeScale = debugTimeScale == TubeGameDebugPlayback.slowMotionScale
                    ? 1
                    : TubeGameDebugPlayback.slowMotionScale
                lastTickDate = nil
            } label: {
                Label(
                    debugTimeScale == TubeGameDebugPlayback.slowMotionScale ? "0.1×" : "Slow-mo",
                    systemImage: "tortoise.fill"
                )
                .font(.appCaption(.bold).monospacedDigit())
                .frame(minWidth: 72, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                debugTimeScale == TubeGameDebugPlayback.slowMotionScale
                    ? Color.black
                    : Color.primary
            )
            .background(
                debugTimeScale == TubeGameDebugPlayback.slowMotionScale
                    ? Color.orange
                    : Color.clear,
                in: .capsule
            )
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Debug super slow motion")
            .accessibilityValue(
                debugTimeScale == TubeGameDebugPlayback.slowMotionScale
                    ? "On, ten percent speed"
                    : "Off, normal speed"
            )

            Button {
                debugPlaybackIsPaused.toggle()
                lastTickDate = nil
            } label: {
                Label(
                    debugPlaybackIsPaused ? "Resume" : "Pause",
                    systemImage: debugPlaybackIsPaused ? "play.fill" : "pause.fill"
                )
                .font(.appCaption(.bold))
                .frame(minWidth: 68, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(debugPlaybackIsPaused ? Color.black : Color.primary)
            .background(
                debugPlaybackIsPaused ? Color.yellow : Color.clear,
                in: .capsule
            )
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(
                debugPlaybackIsPaused ? "Resume debug playback" : "Pause debug playback"
            )
            .accessibilityHint("Freezes gameplay without covering the map")
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    private func debugControlsAreVisible(for phase: TubeGamePhase) -> Bool {
        switch phase {
        case .countdown, .playing:
            true
        case .ready, .paused, .ended:
            false
        }
    }
#endif

    private func gameplayIsAccessible(_ phase: TubeGamePhase) -> Bool {
        switch phase {
        case .countdown, .playing:
            true
        case .ready, .paused, .ended:
            false
        }
    }

    @ViewBuilder
    private func gameChrome(
        snapshot: TubeGameSnapshot,
        camera: TubeGameCameraState,
        size: CGSize
    ) -> some View {
        let landscape = size.width > size.height
        let safeAreaInsets = TubeGameWindowMetrics.safeAreaInsets

        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    engine.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Pause game")

                TubeGameHUD(snapshot: snapshot)
                    .frame(maxWidth: landscape ? 420 : .infinity)

                if landscape {
                    TubeGameMiniMap(
                        model: renderModel,
                        snapshot: snapshot,
                        camera: camera
                    )
                }
            }

            if dynamicTypeSize.isAccessibilitySize, !landscape {
                VStack(alignment: .trailing, spacing: 10) {
                    TubeGameIntentBadge(snapshot: snapshot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TubeGameMiniMap(
                        model: renderModel,
                        snapshot: snapshot,
                        camera: camera
                    )
                }
            } else {
                HStack(alignment: .top) {
                    TubeGameIntentBadge(snapshot: snapshot)
                    Spacer(minLength: 12)
                    if !landscape {
                        TubeGameMiniMap(
                            model: renderModel,
                            snapshot: snapshot,
                            camera: camera
                        )
                    }
                }
            }

            Spacer()

            if voiceOverEnabled {
                TubeGameDirectionPad(onDirection: queue)
                    .padding(.bottom, max(12, safeAreaInsets.bottom))
            }
        }
        .padding(.top, max(10, safeAreaInsets.top + 8))
        .padding(.horizontal, 12)
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func phaseOverlay(snapshot: TubeGameSnapshot, size: CGSize) -> some View {
        switch snapshot.phase {
        case .ready:
            TubeGameReadyView(
                bestScore: highScores.bestScore,
                scores: highScores.scores,
                onStart: engine.start,
                onDismiss: onDismiss
            )
            .transition(overlayTransition)

        case let .countdown(remaining):
            TubeGameCountdownView(remaining: remaining)
                .transition(overlayTransition)
                .allowsHitTesting(false)

        case .playing:
            EmptyView()

        case .paused:
            TubeGamePauseView(
                onResume: engine.resume,
                onEnd: engine.quit
            )
            .transition(overlayTransition)

        case let .ended(reason):
            TubeGameResultsView(
                snapshot: snapshot,
                reason: reason,
                record: submittedRecord,
                isNewBest: isNewBest,
                onPlayAgain: playAgain,
                onDismiss: onDismiss
            )
            .transition(overlayTransition)
        }
    }

    private var overlayTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
    }

    private func queue(_ direction: TubeGameDirection) {
        directionFeedback.selectionChanged()
        engine.queue(direction: direction)
        directionFeedback.prepare()
    }

    private func playStationConsumptionFeedback() {
        stationFeedbackTask?.cancel()
        stationFeedback.impactOccurred(intensity: 0.6)
        stationFeedback.prepare()
        stationFeedbackTask = Task { @MainActor [stationFeedback] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            stationFeedback.impactOccurred(intensity: 0.4)
            stationFeedback.prepare()
        }
    }

    private func playAgain() {
        submittedRecord = nil
        isNewBest = false
        engine.restart(seed: UInt64.random(in: UInt64.min ... UInt64.max))
        engine.start()
    }

    private func handlePhaseChange(_ phase: TubeGamePhase) {
        switch phase {
        case .countdown, .playing:
            if lastTickDate == nil {
                lastTickDate = Date()
            }
        case .ready, .paused, .ended:
            lastTickDate = nil
        }

        guard case let .ended(reason) = phase,
              submittedRecord == nil,
              let record = engine.scoreRecord()
        else { return }

        let previousBest = highScores.bestScore
        if reason != .manualQuit {
            highScores.submit(record)
            isNewBest = highScores.scores.first?.id == record.id
                && record.score >= previousBest
        }
        submittedRecord = record

        let feedback = UINotificationFeedbackGenerator()
        switch reason {
        case .collision:
            feedback.notificationOccurred(.error)
        case .completed, .networkCleared:
            feedback.notificationOccurred(.success)
        case .manualQuit:
            break
        }
    }
}

#if DEBUG
enum TubeGameDebugPlayback {
    static let slowMotionScale: TimeInterval = 0.1

    static func scaledDelta(
        _ delta: TimeInterval,
        timeScale: TimeInterval,
        isPaused: Bool
    ) -> TimeInterval {
        guard !isPaused,
              delta.isFinite,
              delta > 0,
              timeScale.isFinite,
              timeScale > 0 else {
            return 0
        }
        return delta * timeScale
    }
}
#endif

@MainActor
private enum TubeGameWindowMetrics {
    static var safeAreaInsets: EdgeInsets {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                lhs.activationState == .foregroundActive
                    && rhs.activationState != .foregroundActive
            }
        guard let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        else { return EdgeInsets() }

        let insets = window.safeAreaInsets
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }
}

private struct TubeGameHUD: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let snapshot: TubeGameSnapshot

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactMetrics
            } else {
                regularMetrics
            }
        }
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 10 : 16)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .frame(minHeight: 64)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var regularMetrics: some View {
        HStack(spacing: 0) {
            metric(
                title: "TIME",
                value: timeText,
                symbol: snapshot.remainingTime <= 10
                    ? "clock.badge.exclamationmark"
                    : "clock"
            )

            Divider()
                .frame(height: 38)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 5 : 14)

            metric(title: "SCORE", value: "\(snapshot.score)", symbol: "star.fill")

            Divider()
                .frame(height: 38)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 5 : 14)

            metric(
                title: "STATIONS",
                value: "\(snapshot.stationsEaten)",
                symbol: "smallcircle.filled.circle"
            )
        }
    }

    private var compactMetrics: some View {
        HStack(spacing: 12) {
            compactMetric(
                value: timeText,
                symbol: snapshot.remainingTime <= 10
                    ? "clock.badge.exclamationmark"
                    : "clock",
                tint: snapshot.remainingTime <= 10 ? warningColour : .primary
            )
            compactMetric(value: "\(snapshot.score)", symbol: "star.fill", tint: .primary)
            compactMetric(
                value: "\(snapshot.stationsEaten)",
                symbol: "smallcircle.filled.circle",
                tint: .primary
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func compactMetric(value: String, symbol: String, tint: Color) -> some View {
        Label(value, systemImage: symbol)
            .font(.appHeadline(.bold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
    }

    private func metric(title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 1) {
            Label(title, systemImage: symbol)
                .font(.appCaption2(.bold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
            Text(value)
                .font(.appTitle3(.bold).monospacedDigit())
                .foregroundStyle(
                    title == "TIME" && snapshot.remainingTime <= 10
                        ? warningColour
                        : Color.primary
                )
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    private var timeText: String {
        let seconds = max(0, Int(ceil(snapshot.remainingTime)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var warningColour: Color {
        colorScheme == .dark
            ? .orange
            : Color(red: 0.62, green: 0.25, blue: 0.02)
    }
}

private struct TubeGameIntentBadge: View {
    let snapshot: TubeGameSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if let direction = snapshot.queuedDirection {
                Image(systemName: direction.symbol)
                    .font(.appHeadline(.bold))
                    .frame(width: 26, height: 26)
                    .background(.yellow, in: Circle())
                    .foregroundStyle(.black)
                Text("Next: \(direction.title)")
                    .font(.appCaption(.bold))
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Following current line")
                    .font(.appCaption(.semibold))
            }

            if let line = snapshot.comboLineID, snapshot.sameLineStreak > 1 {
                Divider().frame(height: 20)
                Circle()
                    .fill(Color.tubeLine(line))
                    .frame(width: 9, height: 9)
                Text("\(snapshot.sameLineStreak)-station streak")
                    .font(.appCaption(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

private struct TubeGameReadyView: View {
    let bestScore: Int
    let scores: [TubeGameScoreRecord]
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 12) {
                        StationChaseGlyph(mouthAngle: 30)
                            .scaleEffect(2.35)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("STATION CHASE")
                                .font(.appTitle(.bold))
                            Text("A 60-second network run")
                                .font(.appSubheadline(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        rule(
                            symbol: "smallcircle.filled.circle",
                            title: "Eat stations",
                            detail: "Interchanges score more. Stay on the same line to build a combo."
                        )
                        rule(
                            symbol: "hand.draw.fill",
                            title: "Choose your next turn",
                            detail: "Swipe in any of eight directions. Your choice applies at the next junction."
                        )
                        rule(
                            symbol: "tram.fill",
                            title: "Avoid every train",
                            detail: "One collision ends the run. All 20 lines are in play."
                        )
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LOCAL BEST")
                                .font(.appCaption2(.bold))
                                .foregroundStyle(.secondary)
                            Text("\(bestScore)")
                                .font(.appTitle(.bold).monospacedDigit())
                        }
                        Spacer()
                        Text("Start: Oxford Circus")
                            .font(.appCaption(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if !scores.isEmpty {
                        TubeGameLeaderboard(scores: scores)
                    }

                    Button(action: onStart) {
                        Label("Start 60-second run", systemImage: "play.fill")
                            .font(.appHeadline(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.yellow, in: .rect(cornerRadius: 16))
                    .accessibilityHint("Begins at Oxford Circus after a three-second countdown")
                }
                .padding(24)
                .frame(maxWidth: 560)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .padding(.horizontal, 16)
                .padding(.vertical, 54)
            }

            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close Station Chase")
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private func rule(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.appHeadline(.bold))
                .foregroundStyle(.yellow)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appHeadline(.bold))
                Text(detail)
                    .font(.appSubheadline())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TubeGameLeaderboard: View {
    let scores: [TubeGameScoreRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCAL TOP TEN")
                .font(.appCaption2(.bold))
                .foregroundStyle(.secondary)

            ForEach(Array(scores.prefix(10).enumerated()), id: \.element.id) { index, record in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.appCaption(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text("\(record.score)")
                        .font(.appHeadline(.bold).monospacedDigit())
                    Spacer()
                    Text("\(record.stationsEaten) station\(record.stationsEaten == 1 ? "" : "s")")
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                    Text(record.playedAt, format: .dateTime.day().month(.abbreviated))
                        .font(.appCaption2())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

private struct TubeGameCountdownView: View {
    let remaining: TimeInterval

    var body: some View {
        VStack(spacing: 8) {
            Text("\(max(1, Int(ceil(remaining))))")
                .font(AppTypography.fixedHeading(size: 88, weight: .bold))
                .monospacedDigit()
            Text("Swipe in any of eight directions")
                .font(.appHeadline(.bold))
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting in \(max(1, Int(ceil(remaining))))")
    }
}

private struct TubeGamePauseView: View {
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.44).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "pause.fill")
                    .font(.appTitle(.bold))
                Text("Run paused")
                    .font(.appTitle2(.bold))
                Text("Resume when you’re ready. You’ll get a short countdown before the trains move again.")
                    .font(.appSubheadline())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Resume run", action: onResume)
                    .font(.appHeadline(.bold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.yellow, in: .rect(cornerRadius: 15))

                Button("End run", role: .destructive, action: onEnd)
                    .font(.appHeadline(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: 400)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding(20)
        }
    }
}

private struct TubeGameResultsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(TubeGameHighScoreStore.self) private var highScores

    let snapshot: TubeGameSnapshot
    let reason: TubeGameScoreEndReason
    let record: TubeGameScoreRecord?
    let isNewBest: Bool
    let onPlayAgain: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.46).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: reason.symbol)
                        .font(AppTypography.fixedHeading(size: 38, weight: .bold))
                        .foregroundStyle(reason == .collision ? .red : .yellow)
                        .symbolEffect(.bounce, value: snapshot.score)

                    VStack(spacing: 3) {
                        Text(reason.title)
                            .font(.appTitle2(.bold))
                        Text(reason.detail)
                            .font(.appSubheadline())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if isNewBest {
                        Label("New local best", systemImage: "trophy.fill")
                            .font(.appCaption(.bold))
                            .foregroundStyle(accentTextColour)
                    } else if let record,
                              highScores.scores.contains(where: { $0.id == record.id }) {
                        Label("Added to your local top ten", systemImage: "list.number")
                            .font(.appCaption(.bold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 2) {
                        Text("SCORE")
                            .font(.appCaption2(.bold))
                            .foregroundStyle(.secondary)
                        Text("\(snapshot.score)")
                            .font(AppTypography.fixedHeading(size: 58, weight: .bold))
                            .monospacedDigit()
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 26) {
                            resultMetrics
                        }
                        VStack(spacing: 12) {
                            resultMetrics
                        }
                    }

                    Button(action: onPlayAgain) {
                        Label("Play again", systemImage: "arrow.clockwise")
                            .font(.appHeadline(.bold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.yellow, in: .rect(cornerRadius: 15))

                    if reason != .manualQuit, let record {
                        ShareLink(item: highScores.shareText(for: record)) {
                            Label("Share score", systemImage: "square.and.arrow.up")
                                .font(.appHeadline(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 15))
                    }

                    Button("Back to map", action: onDismiss)
                        .font(.appHeadline(.semibold))
                        .frame(minHeight: 44)
                }
                .padding(24)
                .frame(maxWidth: 450)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .padding(.horizontal, 18)
                .padding(.vertical, 48)
            }
        }
    }

    private func resultMetric(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.appTitle3(.bold).monospacedDigit())
            Text(title)
                .font(.appCaption2(.bold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.capitalized), \(value)")
    }

    @ViewBuilder
    private var resultMetrics: some View {
        resultMetric(title: "STATIONS", value: "\(snapshot.stationsEaten)")
        resultMetric(title: "BEST STREAK", value: "\(snapshot.maximumSameLineStreak)")
        resultMetric(title: "LOCAL BEST", value: "\(highScores.bestScore)")
    }

    private var accentTextColour: Color {
        colorScheme == .dark
            ? .yellow
            : Color(red: 0.50, green: 0.31, blue: 0.00)
    }
}

private struct TubeGameDirectionPad: View {
    let onDirection: (TubeGameDirection) -> Void

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                button(.northWest)
                button(.north)
                button(.northEast)
            }
            GridRow {
                button(.west)
                directionPadCentre
                button(.east)
            }
            GridRow {
                button(.southWest)
                button(.south)
                button(.southEast)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityLabel("Direction controls")
    }

    private var directionPadCentre: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.appCaption(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }

    private func button(_ direction: TubeGameDirection) -> some View {
        Button {
            onDirection(direction)
        } label: {
            Image(systemName: direction.symbol)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityLabel("Go \(direction.title.lowercased())")
    }
}

private struct TubeGameLoadingView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                StationChaseGlyph()
                    .scaleEffect(2.5)
                    .frame(width: 50, height: 50)
                ProgressView()
                Text("Preparing the network…")
                    .font(.appHeadline())
            }
            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Station Chase")
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
    }
}

private struct TubeGameLoadFailureView: View {
    let message: String
    let onDismiss: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Station Chase unavailable", systemImage: "tram.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
            Button("Back to map", action: onDismiss)
        }
    }
}

private extension TubeGameDirection {
    var symbol: String {
        switch self {
        case .north: "arrow.up"
        case .northEast: "arrow.up.right"
        case .east: "arrow.right"
        case .southEast: "arrow.down.right"
        case .south: "arrow.down"
        case .southWest: "arrow.down.left"
        case .west: "arrow.left"
        case .northWest: "arrow.up.left"
        }
    }

    var title: String {
        switch self {
        case .north: "North"
        case .northEast: "North-east"
        case .east: "East"
        case .southEast: "South-east"
        case .south: "South"
        case .southWest: "South-west"
        case .west: "West"
        case .northWest: "North-west"
        }
    }
}

private extension TubeGameScoreEndReason {
    var title: String {
        switch self {
        case .completed: "Time’s up"
        case .collision: "Caught by a train"
        case .networkCleared: "Network cleared"
        case .manualQuit: "Run ended"
        }
    }

    var detail: String {
        switch self {
        case .completed: "Your 60-second run is complete."
        case .collision: "One touch is all it takes. The train ended your run."
        case .networkCleared: "You ate every available station. Remarkable work."
        case .manualQuit: "This run was not added to your local top ten."
        }
    }

    var symbol: String {
        switch self {
        case .completed: "clock.badge.checkmark"
        case .collision: "tram.fill"
        case .networkCleared: "trophy.fill"
        case .manualQuit: "stop.fill"
        }
    }
}
