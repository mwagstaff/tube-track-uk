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
