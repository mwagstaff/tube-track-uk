# TubeTrack UK

TubeTrack UK is a native, iPhone-only iOS 26 app for exploring the London
Underground as a schematic network or on an Apple map. It combines a bundled
offline Tube graph with live Transport for London status, planned work and
arrival-prediction data.

## Run the app

1. Open `TubeTrackUK.xcodeproj` in Xcode 26 or later.
2. Select the `TubeTrackUK` scheme and an iPhone running iOS 26 or later.
3. Build and run.

The public TfL endpoints currently work without a key for development. For a
registered key, copy `Configuration/Secrets.example.xcconfig` to
`Configuration/Secrets.xcconfig` and set `TFL_API_KEY`. The secrets file is
ignored by Git and is included conditionally by `Shared.xcconfig`.

## MVP features

- vector, octilinear schematic map with pan, pinch zoom and map hit testing;
- MapKit view using the same station, segment, disruption and train state;
- 11 centrally defined Tube line styles and a 272-station bundled network;
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
fallback, TfL date decoding, train interpolation and works deduplication.

## Refreshing the bundled graph

`Tools/TubeGraphBuilder/build_graph.py` compiles the current topology and TfL
route geometry into `TubeTrackUK/Resources/TubeGraph.json`. The iOS app never
runs this script at launch.

```sh
python3 Tools/TubeGraphBuilder/build_graph.py
```

Review the generated asset and rerun the tests after any network update.

## Attribution

Data provided by Transport for London. The real-world view uses Apple MapKit
and leaves Apple's attribution visible. TubeTrack UK is an independent app by
SkyNoLimit and is not affiliated with or endorsed by Transport for London.
