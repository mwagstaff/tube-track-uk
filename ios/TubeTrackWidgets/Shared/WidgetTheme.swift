import SwiftUI
import TubeTrackCore
import WidgetKit

/// A line's identity mark. Full colour shows the roundel-style dot; accented
/// and vibrant renderings drop colour, so the short code carries the meaning.
struct WidgetLineMark: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let lineID: TubeLineID
    var size: CGFloat = 10

    var body: some View {
        if renderingMode == .fullColor {
            TubeLineDot(lineID: lineID, size: size)
        } else {
            Text(lineID.shortCode)
                .font(.system(size: min(11, max(8, size * 0.72)), weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                // A fixed width keeps the text after the mark aligned down a list.
                .frame(minWidth: min(36, size * 3.4))
                .background(.secondary.opacity(0.25), in: .capsule)
                .widgetAccentable()
                .accessibilityHidden(true)
        }
    }
}

/// Status glyph: colour in full-colour mode, tint-neutral otherwise. The
/// symbol shape is the same in both, so status is never colour-only.
struct WidgetStatusGlyph: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let condition: LineServiceCondition
    var font: Font = .caption

    var body: some View {
        Image(systemName: condition.symbolName)
            .font(font)
            .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(condition.tint) : AnyShapeStyle(.primary))
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

extension View {
    /// The shared widget surface. Full colour gets the system background; the
    /// system supplies Liquid Glass in tinted, clear and StandBy renderings.
    func tubeTrackWidgetContainer() -> some View {
        containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

extension Text {
    /// Status headline styled for full-colour and neutral renderings.
    func statusTint(_ condition: LineServiceCondition, renderingMode: WidgetRenderingMode) -> Text {
        renderingMode == .fullColor ? foregroundStyle(condition.tint) : self
    }
}
