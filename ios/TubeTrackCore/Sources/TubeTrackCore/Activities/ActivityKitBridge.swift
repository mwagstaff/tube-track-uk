#if canImport(ActivityKit)
import ActivityKit

/// The `ActivityAttributes` conformance lives in its own file, separate from
/// the type it conforms.
///
/// Declaring it here keeps the conformance in the same module as the type
/// (so the app and the widget extension are not retroactively conforming a
/// type they don't own), while the `canImport` guard keeps `TubeTrackCore`
/// buildable anywhere ActivityKit isn't available.
extension DepartureActivityAttributes: ActivityAttributes {}
#endif
