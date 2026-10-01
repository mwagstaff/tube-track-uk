# Map initial-touch performance — 28 September 2026

Touching either map changes shared chrome state. Both map renderers remain mounted for camera preservation and the map transition, so this can update the hidden renderer as well as the visible one.

## Findings and changes

- `RealWorldMapRenderData.polylines(covering:)` rebuilt route chains and allocated new `MKPolyline` objects for unchanged segment sets. Touch-state and continuous camera updates could therefore replace the overlay inputs to MapKit. Retain a bounded eight-entry working set per graph, reuse the prebuilt full-network overlays, and return immediately for empty groups. Disruption and mobile-coverage changes still select their own geometry. Apple documents the supplied-overlay initializer in [MapPolyline](https://sosumi.ai/documentation/mapkit/mappolyline/init(_:)-93u7w).
- The tube map computed label exclusion geometry for the river layer whenever its body updated, even with an unchanged rendering camera. Cache this geometry for hit testing and river labels using the existing label-render inputs. Camera, presentation, graph, document, appearance, viewport and Dynamic Type changes invalidate it. The actual label drawing algorithm is unchanged.
- Mobile coverage rebuilt the graph's segment dictionary inside each segment iteration, twice per update. Resolve the dictionary once for the coverage passes.
- The shared tab-bar controller installed a new appearance whenever controls hid or returned. Change alpha and interaction state without reinstalling an unchanged background appearance.

The gesture recognizers, immediate camera updates, momentum and selection behavior remain unchanged.

## Verification

Debug build, iPhone 17 Pro simulator, iOS 26.5. A deterministic test requested affected, unaffected and empty overlay groups 120 times against the bundled graph:

| Measurement | Before | After |
| --- | ---: | ---: |
| Total route-geometry request time | 470.52 ms | 0.43 ms |
| Overlay identity retained across updates | No | Yes |

The two original regression tests failed against the old implementation on overlay identity, then passed after caching. The final run passed 101 tests across map rendering, gesture delivery, camera layers, momentum/performance policies, map lifecycle and morph transitions. New tests also check scope changes, full-network reuse, cache ownership and label invalidation for camera, selection, Dark Mode and Dynamic Type. Build and whitespace checks passed.

This benchmark measures repeated geometry requests, not total frame time or finger-to-screen latency. No physical-device latency measurement or visual review was completed: the computer-use service could not open the Simulator application. Existing hosted-view lifecycle tests did run in the simulator, including map preservation across tab switches. For device confirmation, use Instruments Time Profiler and Animation Hitches during the first flick in each map mode, with river and mobile coverage both enabled and disabled; check for any remaining gesture-time label/layout work or overlay recreation.

## Follow-up: intermittent scrolling hitches — 1 October 2026

The remaining pan paths contained work at buffer boundaries:

- The tube-map artwork rebases after roughly 192 points of travel. Label drawing still ran its own collision solver, while the hit-test/river geometry cache also invalidated on every rebase. Layout could change with the viewport, producing visible label shifts. Network labels now use a stable layout rectangle based on artwork bounds, scale and presentation; pan rebases only translate and cull those placements. Drawing, hit testing and river exclusions share that layout. Text is resolved only for placements intersecting the current buffer. Journey maps retain their viewport-constrained layout.
- Geographic station culling replaced the annotation set when a moving viewport reached its buffer boundary. The bounded network station set now stays installed while roundels are shown; MapKit handles onscreen visibility. Zoom styling still changes when the camera settles. This trades a larger installed annotation set for avoiding SwiftUI Map content changes during long pans.
- Momentum advanced by `targetTimestamp - timestamp`, which describes a refresh interval rather than time since the last delivered update. It now advances using consecutive target times, starting at release, and integrates exponential deceleration exactly. Missed frames no longer prolong the coast or change its distance. Long suspensions are capped at the existing maximum duration. See Apple's [targetTimestamp documentation](https://sosumi.ai/documentation/quartzcore/cadisplaylink/targettimestamp).

Validation: 112 tests passed across two targeted runs, including real hosted-map tests that cross multiple artwork rebase boundaries and retain geographic annotation identities through long camera moves. Irregular momentum timing (including a 250 ms gap), timestamp validity, projected label positions, cache invalidation, gesture interruption, map lifecycle, label collision behavior and journey maps are covered. Light and dark tube-map renders were generated from the hosted test and visually inspected at scale 0.6 with labels visible. Build and whitespace checks passed.

These checks establish the removed work and preserved rendering/gesture behavior; they are not a physical-device frame-time measurement. Device verification with Instruments Animation Hitches remains useful for any residual GPU/compositing or live-update stalls.
