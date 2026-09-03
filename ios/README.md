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

Use `--fail-on high` in CI to reject source-hash, canvas-transform, topology,
detached-symbol and skewed-tick failures. Non-octilinear route and connector
angles remain medium-severity review candidates because the official artwork
contains deliberate exceptions; correct them only when the locked overlay
shows a source mismatch.

The final map compiler runs `normalize_station_markers.py` after every rail mode
has been composed. That pass promotes connector-linked ordinary ticks to
interchange roundels and derives visibly skewed ticks from their closest local
route tangent. It is idempotent, so rerunning it must not change a current
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
