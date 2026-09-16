# TubeTrack UK

TubeTrack UK is a native, iPhone-only iOS 26 app for exploring London
Underground, DLR, Elizabeth line, London Overground and London Trams services
on an authored network map or on an Apple map. It combines a bundled offline
rail graph with live Transport for London status, planned work and
arrival-prediction data.

## Run the app

1. Open `TubeTrackUK.xcodeproj` in Xcode 26 or later.
2. Select the `TubeTrackUK` scheme and an iPhone running iOS 26 or later.
3. Build and run.

Live data is fetched from the Tube Track API at
`https://api.skynolimit.dev/tube-track`. TfL credentials are held only by that
server; the app does not store or send a TfL API key.

## MVP features

- authored Underground map with pan, pinch zoom and map hit testing;
- MapKit view using the same station, segment, disruption and train state;
- 20 centrally defined rail line styles and a 509-station-record bundled network;
- 30-second live status refresh with section-aware disruption resolution;
- Normal/Issues highlighting, collapsible status panel and cached fallback;
- estimated moving trains from TfL predictions, with a 20-second refresh and
  all-lines/single-line filtering;
- station selection with live departures and affected-station status;
- chronological planned works with date/line filters, detail and map links;
- system light/dark mode, Dynamic Type, VoiceOver representations and Reduce
  Motion support;
- no account, analytics or location permission.

Train markers are prediction-based estimates rather than GPS positions. The app
labels cached/stale status explicitly and keeps the static network available if
TfL is temporarily unreachable.

## Verification

Run the unit suite with:

```sh
xcodebuild test \
  -project TubeTrackUK.xcodeproj \
  -scheme TubeTrackUK \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

Tests cover bundled graph integrity, disruption section resolution and safe
fallback, API response decoding, train interpolation and works deduplication.

## Journey planning

The Journeys tab replaces the former Works tab. Choose two rail stations, then
Leave now, Depart at or Arrive by. Step-free preferences distinguish access to
the platform from access to the train. Results compare estimated arrival times
and retain a less-disrupted alternative where TfL supplies one. Search progress
is shown in the button, then route choices open on a separate screen with Back
navigation. Results and leg details use labelled line-colour dots. Route details
include changes, walking, stops and station/line notices. All times are shown
in London time; journey results are estimates and have a short explicit expiry.

Journey details can open a separate network map with the selected rail sections
in line colours and blue rings around the start, end and change stations. This
uses the bundled, immutable network artwork and an independent camera. The
resolver follows TfL stop order through the known line routes, groups interchange
aliases, and only accepts missing-ID name matches at a unique station hub.
Ambiguous or unmatched legs are disclosed rather than guessed. Walking directions
remain in the journey details. Refreshing keeps the previous choices visible,
with their original expiry, while checking again.

Engineering Works remains accessible through the expanded disruptions lozenge
on the map. Its map actions dismiss Works and focus the affected sections.

Deploy the companion API with `/api/v1/journeys` before releasing this app.
For local simulator integration, Debug builds accept
`-DebugAPIBaseURL http://127.0.0.1:3018`; this is limited to loopback hosts and
is absent from Release builds. For visual QA, combine `-DebugJourneySearch`
with `-DebugJourneyFrom <station ID>` and `-DebugJourneyTo <station ID>`.
`-DebugJourneyDestination details` or `map` opens that screen after the search.
These options are Debug-only. No TfL credential belongs in the app.

## Offline use

The network map, station search, mobile coverage overlay and Track-Man use
bundled data and work on a first launch without internet access. Losing the
connection returns an open real-world map to the network map. Location can
still use the phone's GPS. Live trains, departures, directions, online maps and
Game Center rankings become unavailable; their controls appear disabled.

Status and planned works load immediately from saved snapshots before any
network request. Each successful response is saved in Application Support,
with migration from older caches, and retains the server's update time. While
the app is active and online, it checks status every 30 seconds and planned
works every 5 minutes, and refreshes on returning to the app or reconnecting.
The server may reuse its own cached results. Offline snapshots have no expiry;
the banner shows their age, and dates outside the saved works range are marked
as incomplete. A first launch with no snapshot says no data has been saved.

Game scores and achievements remain local offline. Completed runs are also
queued for Game Center and retried when a connection and authentication are
available. Playing never requires sign-in.

For simulator checks, launch a Debug build with `-DebugOffline` to exercise
offline presentation and suppress app API requests. Check station search,
selection, map pan/pinch/momentum, both mobile coverage modes, game completion
and restart, light/dark appearance, and larger Dynamic Type. On a device,
repeat with Wi-Fi and cellular disabled, then reconnect and verify that live
controls and disruption updates resume.

## Profiling network-map navigation

The network map retains viewport-sized Canvas surfaces with a 240-point buffer
for routes, station labels and trains. `BeckMapLayerCamera` moves their Core
Animation layers directly during pan, pinch and momentum. Camera motion is not
observable SwiftUI state; only a buffer refresh, selection, data or appearance
change rebuilds the drawing. Buffer refreshes present synchronously so the drawing and
its camera transform stay aligned. Label hit testing uses the rendered buffer's
coordinates, including when a tap stops momentum.

Touch-driven pan and pinch updates are applied directly from UIKit, including
the movement already accumulated when recognition begins. CADisplayLink is used
only for momentum and programmatic camera animations. Touch-down catches a
coasting map immediately; changing from momentum to a new gesture does not
publish an intermediate viewport or briefly restore the map furniture.

For on-device verification, run a Release build with Instruments' Animation
Hitches and Time Profiler templates. Record repeated drags, long flicks and
pinches near each screen corner, with live trains off and on. Include drags from
rest, grabbing the map during momentum and catching an automatic zoom with a
touch; check the delay before the first visible movement as well as steady motion.
Check 60 Hz and
ProMotion devices, light/dark appearance, larger Dynamic Type and Reduce Motion.
Steady motion should spend time in layer transforms, with `BeckMapCanvas.body`
and label collision layout appearing only at buffer refreshes or other content
changes. Inspect memory as well as hitch duration; surfaces are bounded to the
viewport plus padding rather than the full network at maximum zoom.

The September 2026 layout comparison used 144-label dense scenes and 300
iterations of optimized Swift on the development Mac. Early-exit candidate
selection took 0.754/0.524/0.331 ms versus 0.945/0.866/0.507 ms for the previous
exhaustive search at fixture scales 0.65/1/1.6. These are layout-only timings,
not on-device frame rates. Regression tests compare placement results with the
previous algorithm and replay 240 camera frames without observation invalidation.

## Refreshing the bundled graph

`Tools/TubeGraphBuilder/build_graph.py` compiles the current Tube, DLR,
Elizabeth, six named Overground and London Trams topologies and TfL route
geometry into `TubeTrackUK/Resources/TubeGraph.json`. The iOS app never runs
this script at launch.

```sh
python3 Tools/TubeGraphBuilder/build_graph.py
```

Review the generated asset and rerun the tests after any network update.

For detailed geographic geometry, pass a reproducible OSM PBF containing
`route=subway`, `route=light_rail`, `route=train`, and `route=tram` relations.
Reviewed OSM geometry for every supported TfL rail line is retained during
API-only refreshes; TfL route geometry is used as the fallback.

## Auditing authored map fidelity

The structural fidelity audit checks every route command, roundel, ordinary
station tick and interchange connector against the locked April 2026 TfL
reference and TfL-style geometric invariants. It never edits map coordinates.

From the `ios` directory, regenerate the tracked baseline reports with:

```sh
python3 Tools/BeckMapBuilder/audit_map_fidelity.py \
  --document TubeTrackUK/Resources/BeckMap/v1/full-underground.json \
  --graph TubeTrackUK/Resources/TubeGraph.json \
  --manifest design_brief/beck_map/tfl-standard-map-april-2026.json \
  --output-json design_brief/beck_map/audits/april-2026-structural-fidelity-audit.json \
  --output-markdown design_brief/beck_map/audits/april-2026-structural-fidelity-audit.md \
  --output-html design_brief/beck_map/audits/april-2026-structural-fidelity-audit.html
```

Use `--fail-on critical` while the tracked high-severity review backlog remains
open. Connector angles outside the horizontal, vertical and 45-degree grammar
are high severity unless a stable station-specific expectation has been
measured from the locked source. Route commands remain medium review candidates
because those paths are extracted directly from the official vector artwork.
Move the gate to `--fail-on high` once the remaining connector and symbol
findings have been source-adjudicated.

The final map compiler first runs `normalize_official_geometry.py` to apply
station-specific, source-verified connector and shared-corridor corrections,
then runs `normalize_station_markers.py` after every rail mode has been
composed. The latter promotes connector-linked ordinary ticks to interchange
roundels and derives visibly skewed ticks from their closest local route
tangent. Both passes are idempotent, so rerunning them must not change a current
bundled asset.

## Background images

Add background photographs anywhere under `TubeTrackUK/Images`. The app target's
`Copy Background Images` build phase discovers JPEG, PNG, HEIC, HEIF and WebP
files recursively, converts them to cached JPEGs with a maximum 2,560-pixel edge
and quality 78, copies only those optimized versions into the built app, and
generates the manifest used for hourly random rotation. Adding or removing a
photograph does not require an Xcode project-file change.

Unsplash filenames should retain the
`artist-name-11_character_photo_ID-unsplash` form. The Profile screen uses this
to generate the artist credit and link to the photograph automatically.

## Attribution

Data provided by Transport for London. The real-world view uses Apple MapKit
and leaves Apple's attribution visible. TubeTrack UK is an independent app by
SkyNoLimit and is not affiliated with or endorsed by Transport for London.
