import AppIntents

/// Tapping the refresh glyph on a widget. WidgetKit reloads the widget that
/// hosted the button once any intent completes, and user-initiated reloads do
/// not count against the refresh budget, so the intent itself has nothing to
/// do: it is the passenger's way to get live data between the widget's own
/// refresh windows.
struct RefreshWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Widget"
    static let description = IntentDescription("Fetches the latest live data for this widget.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        .result()
    }
}
