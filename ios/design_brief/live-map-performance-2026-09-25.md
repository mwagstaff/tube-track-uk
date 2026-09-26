# Live map performance investigation — 25 September 2026

The largest observed cost was live work continuing in the invisible geographic map while the schematic map was displayed. Opacity does not stop a SwiftUI timeline or its child views from updating.

## Findings and fixes

- Gate both maps’ train and boat timelines by the active map mode and tab. Keep their base maps mounted for the existing transition and camera state.
- Geographic train accessibility labels rebuilt `TubeGraph.stationsByID` for every marker. Resolve the lookup once outside the timeline, preserving all accessible train buttons.
- Resolve closed-line status once per drawing pass instead of once per train. Reuse each resolved train image within its GraphicsContext rather than resolving the same line artwork hundreds of times. Apply this to both maps and the morph transition.
- A changing train timestamp forced an immediate hosting-view layout. Keep synchronous layout for camera rebases, which require pixels and transforms to commit together; let ordinary vehicle updates use the scheduled layout pass. Apple documents the synchronous behavior of [layoutIfNeeded](https://sosumi.ai/documentation/uikit/uiview/layoutifneeded()).
- Cache directed pier-pair paths and their segment lengths. Boat interpolation and hit testing now reuse geometry; live progress and expiration are still checked each time. Invalidate geographic paths when the network changes and schematic paths when the document changes. Bound each cache to 128 pairs.
- Draw upright `ferry.fill` boat icons on both maps, removing the extra forward-position calculation previously used to rotate arrows. Cull icons outside the drawing bounds.

## Measurements

Debug build, iPhone 17 Pro simulator, iOS 26.5, full-network schematic overview, live API data, all lines selected. Each sample lasted 20 seconds at a requested 1 ms interval. Live fleet counts varied around 800 (792 before; 760–805 across the follow-up run).

| Main-thread samples | Before | After |
| --- | ---: | ---: |
| Total | 16,460 | 16,847 |
| Waiting in `mach_msg2_trap` | 13,542 | 16,566 |
| Non-waiting share | 17.73% | 1.67% |
| Hidden geographic accessibility label stack | 1,136 | 0 |
| Schematic `drawTrains` stack | 507 | 30 |

This is approximately 91% fewer non-waiting main-thread samples during the settled overview. Sampling indicates where work was removed; it is not an FPS or touch-latency benchmark. Different live predictions, simulator scheduling and the Debug build limit precision. The before/after raw samples were saved locally in `/tmp/tubetrack-792-baseline.sample.txt` and `/tmp/tubetrack-760-final.sample.txt`.

## Verification

- Confirmed the full fleet still appears and updates, and selecting a train opens its next-stop callout.
- Visually checked the boat icon in both map modes using a controlled two-poll RB4 fixture, switched between the maps, and selected the boat through its accessible control. Visually confirmed Canada Water’s shared roundel.
- Passed 128 iOS Beck map/repository/camera and River Bus regression tests and 17 offline map-builder tests. Build and whitespace checks also passed. The existing label-tier count assertions were stale against the pre-change bundled map (67 network / 191 local); update those counts without changing any label tiers.
- For device follow-up, use Instruments Time Profiler and Animation Hitches while panning, pinching and switching maps with all services enabled. Compare live-on and live-off runs on the same device. Confirm hidden-map timelines are absent and inspect any remaining gesture-time layout or rendering spikes.
