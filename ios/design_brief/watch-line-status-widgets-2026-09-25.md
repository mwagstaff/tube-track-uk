# Apple Watch line status widgets

## Implemented configuration

The Watch app now has a **Choose widget lines** screen. It saves one shared
rectangular selection of one to three distinct lines in the chosen order and
three independently chosen circular slots. The three circular widget kinds
can be added separately to a Watch face. The original per-instance intent design below was
replaced after the watchOS simulator repeatedly delivered an empty intent to
the widget timeline provider despite showing the saved choices in the editor.
The rectangular widget and Watch app selection were verified in the Smart Stack.
The Watch app's Line Status screen lists the distinct lines selected across
all four widgets in alphabetical order. An All other lines row opens the
remaining services with the same status and detail views.

Each circular slot is now registered as its own concrete WidgetKit widget type,
with a distinct kind and gallery name (Circle 1, Circle 2, Circle 3). Circle 1
keeps its original kind so existing installations retain their configuration.

The tiny clock overlay means the shown line status may be out of date. It
appears immediately for a Watch-side offline fallback or a server response
flagged stale, and otherwise when the status snapshot is ten minutes old.
Normal server cache hits within the status endpoint's one-minute cache do not
trigger it. The Watch widgets request a new timeline every five minutes at
all hours. WidgetKit controls the actual reload time and may defer requests.

For tracked station departures, the iPhone Live Activity opts into the Watch
Smart Stack's small activity family. That layout shows the next two trains'
destinations beside their countdowns, with the tracked station at top left
and a compact line, service-status icon, and direction at top right. The
iPhone Lock Screen and Dynamic Island keep their own layouts.

## Goal

Let a passenger glance at the status of their chosen rail lines on Apple Watch. Offer a rectangular Smart Stack widget / compatible watch-face complication with one to three lines, plus three independently chosen circular complications with one line each.

## Existing foundation

- The iPhone `LineStatusWidget` already has accessory rectangular and circular views, but the Xcode project currently has only iPhone app and widget targets. A Watch app and watchOS widget extension are needed.
- `TubeLineID` provides line identities and short codes. `LineServiceCondition` provides the good, minor disruption, major disruption, overnight closure, and updating classifications and their distinct symbols.
- The current iPhone intent allows any number of lines and treats an empty choice as *all* lines. The existing rectangular and circular views then select up to three or the worst line. Those rules do not meet this Watch feature's explicit selection limits.
- `TubeTrackCore` currently declares only iOS in `Package.swift`; watchOS support needs to be added and compiled, with any platform-specific files gated or split as needed.

## Passenger experience

| Surface | Selection | Layout | Tap |
| --- | --- | --- | --- |
| Rectangular | Require a first line; allow a second and third. Keep the chosen order. | One row per line: compact, recognizable line label at the left and a large status symbol at the right. No reason text. | Open the Watch app's selected-lines status screen. |
| Circular slots 1–3 | Choose one line for each slot. | Short line code and one prominent status symbol. | Open that line's detail in the Watch app. |

Use a dedicated short-label mapping for the rectangular rows (for example, `Central`, `H&C`, `Elizabeth`), with the existing `shortCode` as the narrow-width fallback and the circular label. Do not reorder the chosen lines by severity or silently substitute another line. The three circular slots have separate saved choices.

The status symbols must remain distinguishable without color: checkmark circle for good service, warning triangle for minor disruption, exclamation octagon for major disruption, moon for overnight closure, and an updating/unknown symbol when a line has no reliable status. Use the existing condition colors only as a secondary cue when full-color rendering is available. Give each row a full VoiceOver label such as “Central line, minor delays”; announce stale data separately. Test tinted rendering and Always On appearance.

If the latest request fails, display the last Watch-side cached status with a visible stale marker. If there is no cached status, show an unavailable symbol, never a good-service checkmark. The rectangular widget can show an age label if space allows; the circular widget keeps the symbol and uses a small stale badge. Tapping either surface opens a Watch app screen with the full status wording, reason, and last-updated time.

## Implementation plan

1. **Add Watch targets.** Add a minimal SwiftUI Watch app and a watchOS WidgetKit extension to the existing Xcode project. Support `.accessoryRectangular` and `.accessoryCircular` only in the Watch extension. Use the current project deployment baseline where appropriate and add watchOS support to the reusable core package.
2. **Make configuration explicit.** Save one to three rectangular lines and one line for each of three circular widget kinds in the Watch app's shared preferences. Keep the original circular widget kind for slot 1 so an installed complication retains its choice. Reload only the affected widget kind after a change.
3. **Share status logic, not iPhone layout.** Reuse `TubeLineID`, `LineServiceCondition`, TfL decoding, and the status endpoint. Extract the iPhone provider's row projection into a watch-compatible shared component so both platforms classify missing and disrupted status consistently. Build small Watch-specific SwiftUI views sized for the 40 mm through 49 mm layouts.
4. **Fetch and cache on the Watch.** The Watch widget provider fetches `/api/v1/status` directly, filters to the configured line IDs, and keeps a Watch-side snapshot for offline fallback. Do not assume the iPhone App Group files are available on the Watch. Use a conservative WidgetKit timeline based on the existing refresh policy; show the source timestamp and let WidgetKit decide actual reload timing. Add an explicit reload when the Watch app refreshes status. Avoid a per-minute network poll.
5. **Wire navigation.** A minimal Watch app shows the selected lines and line detail, with status description, reason, and freshness. Handle widget taps through Watch-side links so rectangular and circular widgets lead to the relevant screen.
6. **Verify on real layouts.** Preview and test both families on 40 mm, 41 mm, 44 mm, 45 mm, and 49 mm sizes, in full-color and tinted modes, light/dark where applicable, large text, VoiceOver, Always On, offline, stale cache, and a missing line response. Check that one, two, and three rectangular rows fit without truncating a line label or obscuring an icon. Confirm all three circular slots retain separate selections.

## Acceptance criteria

- A person can choose one to three distinct lines for a rectangular Watch widget and a separate line for each of three circular complications.
- Each configured line is visible in the chosen order with an immediately recognizable status symbol; color is never required to interpret it.
- Unavailable and stale data are visibly distinct from good service.
- The Watch app opens to the relevant status from either widget, and the widgets remain useful when the paired iPhone is absent.
- The Watch app, Watch widget extension, and shared package build for watchOS; the existing iPhone widget behavior still works.

## Apple guidance

- [Accessory widgets and Watch complications](https://sosumi.ai/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
- [Configurable widgets and Watch recommendations](https://sosumi.ai/documentation/widgetkit/making-a-configurable-widget)
- [Keeping widgets up to date](https://sosumi.ai/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Complication design](https://sosumi.ai/design/human-interface-guidelines/complications)
- [Widget design and Watch sizes](https://sosumi.ai/design/human-interface-guidelines/widgets)
