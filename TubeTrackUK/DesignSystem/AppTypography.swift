import CoreText
import SwiftUI
import UIKit

enum AppFontWeight {
    case regular
    case medium
    case semibold
    case bold
}

enum AppTypography {
    private static let cabinRegularName = "Cabin-Regular"
    private static let cabinMediumName = "Cabin-Medium"
    private static let cabinSemiboldName = "Cabin-SemiBold"
    private static let cabinBoldName = "Cabin-Bold"
    private static let headingName = "MetropolitanLine-Regular"

    private static let bundledFontFiles = [
        cabinRegularName,
        cabinMediumName,
        cabinSemiboldName,
        cabinBoldName,
        headingName,
    ]

    static func prepare() {
        registerBundledFonts()
        configureUIKitTypography()
    }

    static func body(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: AppFontWeight = .regular
    ) -> Font {
        .custom(cabinName(for: weight), size: size, relativeTo: textStyle)
    }

    static func fixedBody(
        size: CGFloat,
        weight: AppFontWeight = .regular
    ) -> Font {
        .custom(cabinName(for: weight), fixedSize: size)
    }

    static func fixedBodyUIFont(
        size: CGFloat,
        weight: AppFontWeight = .regular
    ) -> UIFont {
        UIFont(name: cabinName(for: weight), size: size)
            ?? UIFont.systemFont(ofSize: size, weight: uiFontWeight(for: weight))
    }

    static func heading(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: AppFontWeight = .regular
    ) -> Font {
        var font = Font.custom(headingName, size: size, relativeTo: textStyle)
        switch weight {
        case .regular:
            break
        case .medium:
            font = font.weight(.medium)
        case .semibold:
            font = font.weight(.semibold)
        case .bold:
            font = font.weight(.bold)
        }
        return font
    }

    static func fixedHeading(
        size: CGFloat,
        weight: AppFontWeight = .regular
    ) -> Font {
        var font = Font.custom(headingName, fixedSize: size)
        switch weight {
        case .regular:
            break
        case .medium:
            font = font.weight(.medium)
        case .semibold:
            font = font.weight(.semibold)
        case .bold:
            font = font.weight(.bold)
        }
        return font
    }

    private static func cabinName(for weight: AppFontWeight) -> String {
        switch weight {
        case .regular: cabinRegularName
        case .medium: cabinMediumName
        case .semibold: cabinSemiboldName
        case .bold: cabinBoldName
        }
    }

    private static func uiFontWeight(for weight: AppFontWeight) -> UIFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    private static func registerBundledFonts(bundle: Bundle = .main) {
        for fontFile in bundledFontFiles {
            guard let url = bundledFontURL(named: fontFile, bundle: bundle) else {
                assertionFailure("Missing bundled font: \(fontFile).ttf")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &registrationError
            )
            if !registered, UIFont(name: fontFile, size: 17) == nil {
                let errorDescription = registrationError?.takeRetainedValue().localizedDescription
                    ?? "Unknown registration error"
                assertionFailure("Could not register \(fontFile): \(errorDescription)")
            }
        }
    }

    private static func bundledFontURL(named name: String, bundle: Bundle) -> URL? {
        let candidateDirectories: [String?] = [
            "Resources/Fonts",
            "Fonts",
            nil,
        ]
        for directory in candidateDirectories {
            if let url = bundle.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: directory
            ) {
                return url
            }
        }
        return nil
    }

    private static func configureUIKitTypography() {
        let navigationTitleFont = scaledUIFont(
            named: headingName,
            size: 17,
            textStyle: .headline
        )
        let largeNavigationTitleFont = scaledUIFont(
            named: headingName,
            size: 34,
            textStyle: .largeTitle
        )
        UINavigationBar.appearance().titleTextAttributes = [.font: navigationTitleFont]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeNavigationTitleFont]

        let tabFont = scaledUIFont(
            named: cabinMediumName,
            size: 11,
            textStyle: .caption2
        )
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .selected)
    }

    private static func scaledUIFont(
        named name: String,
        size: CGFloat,
        textStyle: UIFont.TextStyle
    ) -> UIFont {
        guard let font = UIFont(name: name, size: size) else {
            assertionFailure("Registered font is unavailable: \(name)")
            return UIFont.preferredFont(forTextStyle: textStyle)
        }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
    }
}

extension Font {
    static func appLargeTitle(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.heading(size: 34, relativeTo: .largeTitle, weight: weight)
    }

    static func appTitle(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.heading(size: 28, relativeTo: .title, weight: weight)
    }

    static func appTitle2(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.heading(size: 22, relativeTo: .title2, weight: weight)
    }

    static func appTitle3(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.heading(size: 20, relativeTo: .title3, weight: weight)
    }

    static func appHeadline(_ weight: AppFontWeight = .semibold) -> Font {
        AppTypography.heading(size: 17, relativeTo: .headline, weight: weight)
    }

    static func appBody(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 17, relativeTo: .body, weight: weight)
    }

    static func appCallout(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 16, relativeTo: .callout, weight: weight)
    }

    static func appSubheadline(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 15, relativeTo: .subheadline, weight: weight)
    }

    static func appFootnote(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 13, relativeTo: .footnote, weight: weight)
    }

    static func appCaption(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 12, relativeTo: .caption, weight: weight)
    }

    static func appCaption2(_ weight: AppFontWeight = .regular) -> Font {
        AppTypography.body(size: 11, relativeTo: .caption2, weight: weight)
    }
}
