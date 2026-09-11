import SwiftUI

struct TubeGameScoreCard: View {
    let record: TubeGameScoreRecord
    let achievements: [TubeGameAchievement]

    var body: some View {
        VStack(spacing: 22) {
            Image("ScoreShareAppIcon")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 20))
            VStack(spacing: 8) {
                Text("TubeTrack UK").font(.system(size: 25, weight: .bold))
                Text("TRACK-MAN").font(.system(size: 12, weight: .bold)).tracking(4)
                    .foregroundStyle(.white.opacity(0.65))
            }
            VStack(spacing: 0) {
                Text(record.score.formatted())
                    .font(.system(size: 100, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text("POINTS").font(.system(size: 12, weight: .bold)).tracking(3)
                    .foregroundStyle(.white.opacity(0.65))
            }
            if !achievements.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "trophy.fill").font(.system(size: 22))
                    ForEach(achievements) { achievement in
                        Text(achievement.message).font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.25))
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 18))
            }
            VStack(spacing: 22) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 22) {
                    metric("STATIONS", record.stationsEaten.formatted())
                    metric("LINES CLEARED", record.linesCleared.formatted())
                    metric("TERMINI", record.terminusStationsReached.formatted())
                    metric("BEST COMBO", record.maxCombo.formatted())
                }
                metric("TIME SURVIVED", "\(record.timeSurvivedSeconds)s")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            Text("Your next stop: beat my score.")
                .font(.system(size: 16, weight: .medium))
            Text(record.playedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(36)
        .frame(width: 480)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.28), Color(red: 0.02, green: 0.04, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    for index in 0..<3 {
                        var rail = Path()
                        let offset = CGFloat(index) * 15
                        rail.move(to: CGPoint(x: -20, y: size.height - 75 + offset))
                        rail.addLine(to: CGPoint(x: 55, y: size.height - 75 + offset))
                        rail.addLine(to: CGPoint(x: 145, y: size.height + 15 + offset))
                        context.stroke(rail, with: .color([Color.cyan, .yellow, .pink][index].opacity(0.65)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

#Preview {
    TubeGameScoreCard(
        record: .init(score: 576, stationsEaten: 29, linesCleared: 1, terminusStationsReached: 2, maxCombo: 8, configuredDuration: 60, elapsedTime: 42, endReason: .collision, runSeed: 1, graphGeneratedAt: "preview"),
        achievements: [.init(category: "score", period: "daily personal", value: 576)]
    )
}
