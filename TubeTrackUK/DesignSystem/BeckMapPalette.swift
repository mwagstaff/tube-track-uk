import SwiftUI

/// Appearance-only colours for the Beck map. Route colours deliberately stay
/// outside this palette so every line continues to use its canonical colour.
struct BeckMapPalette {
    let background: Color
    let paper: Color
    let labelSurface: Color
    let ink: Color
    let stationOutline: Color
    let labelBorder: Color
    let labelBorderWidth: CGFloat
    let labelHorizontalPadding: CGFloat
    let labelVerticalPadding: CGFloat
    let labelCornerRadius: CGFloat
    let waterwayFill: Color
    let waterwayOutline: Color
    let mutedRoute: Color
    let northernLineCasing: Color?
    let northernLineCasingExpansion: CGFloat

    static let light = Self(
        background: .white,
        paper: .white,
        labelSurface: .white.opacity(0.86),
        ink: Color(red: 0.04, green: 0.12, blue: 0.25),
        stationOutline: Color(red: 0.08, green: 0.09, blue: 0.10),
        labelBorder: .clear,
        labelBorderWidth: 0,
        labelHorizontalPadding: 0,
        labelVerticalPadding: 0,
        labelCornerRadius: 2,
        waterwayFill: Color(
            red: 204.0 / 255.0,
            green: 239.0 / 255.0,
            blue: 252.0 / 255.0
        ),
        waterwayOutline: Color(
            red: 25.0 / 255.0,
            green: 181.0 / 255.0,
            blue: 241.0 / 255.0
        ),
        mutedRoute: Color(white: 0.72).opacity(0.48),
        northernLineCasing: nil,
        northernLineCasingExpansion: 0
    )

    /// A mid-slate surface keeps the black Northern line readable while using
    /// much less display luminance than the light map. The fine paper casing
    /// protects its silhouette at crossings without changing the line colour.
    static let dark = Self(
        background: Color(red: 0.34, green: 0.38, blue: 0.43),
        paper: Color(red: 0.95, green: 0.94, blue: 0.91),
        labelSurface: Color(red: 0.035, green: 0.05, blue: 0.075).opacity(0.84),
        ink: Color(red: 0.98, green: 0.98, blue: 0.97),
        stationOutline: Color(red: 0.055, green: 0.065, blue: 0.08),
        labelBorder: Color.white.opacity(0.20),
        labelBorderWidth: 1,
        labelHorizontalPadding: 7,
        labelVerticalPadding: 4,
        labelCornerRadius: 999,
        waterwayFill: Color(red: 0.18, green: 0.39, blue: 0.49),
        waterwayOutline: Color(red: 0.36, green: 0.75, blue: 0.90),
        mutedRoute: Color(red: 0.82, green: 0.84, blue: 0.86).opacity(0.52),
        northernLineCasing: Color(red: 0.95, green: 0.94, blue: 0.91).opacity(0.92),
        northernLineCasingExpansion: 1.5
    )

    static func resolve(
        for colorScheme: ColorScheme,
        preservesReferenceAppearance: Bool = false
    ) -> Self {
        if preservesReferenceAppearance { return .light }
        return colorScheme == .dark ? .dark : .light
    }

    func casingWidth(for lineID: TubeLineID, routeWidth: CGFloat) -> CGFloat? {
        guard lineID == .northern, northernLineCasing != nil else { return nil }
        return routeWidth + northernLineCasingExpansion
    }

    func routeColor(for lineID: TubeLineID, muted: Bool) -> Color {
        muted ? mutedRoute : .tubeLine(lineID)
    }
}
