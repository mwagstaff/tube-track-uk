import SwiftUI

struct GlassPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct TubeTrackMark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 9 : 14)
                    .fill(Color.tubeBlue.gradient)
                Capsule()
                    .fill(Color.tubeLine(.central))
                    .frame(width: compact ? 36 : 53, height: compact ? 5 : 8)
                    .rotationEffect(.degrees(35))
                Capsule()
                    .fill(Color.tubeLine(.victoria))
                    .frame(width: compact ? 36 : 53, height: compact ? 5 : 8)
                    .rotationEffect(.degrees(-35))
                Image(systemName: "tram.fill")
                    .font(.system(size: compact ? 9 : 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 32 : 48, height: compact ? 32 : 48)

            if !compact {
                Text("TubeTrack UK")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TubeTrack UK")
    }
}

struct PlaceholderFeatureView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
                .navigationTitle(title)
        }
    }
}
