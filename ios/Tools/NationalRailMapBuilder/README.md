# Optional National Rail map

Builds the April 2026 London Rail & Tube footprint from the [TfL/Rail Delivery Group reference](https://content.tfl.gov.uk/london-rail-and-tube-services-map.pdf).
The bundled layer contains 171 additional stations and 303 operator corridor sections.
The existing Thameslink layer remains independent of this optional layer.

## Rebuild

Use Python 3 with PyMuPDF and Shapely installed, a local copy of the reference
PDF, and a TrainTrack UK checkout containing its station catalogue and bundled
OSM railway graph. The builder itself makes no network requests.

```sh
rtk proxy python3 ios/Tools/NationalRailMapBuilder/build.py \
  --pdf /path/to/london-rail-and-tube-services-map.pdf \
  --train-track /path/to/train-track-uk
rtk proxy python3 -m unittest discover -s ios/Tools/NationalRailMapBuilder
```

Run this after rebuilding the core National Rail CRS index. Outputs are:

- `TubeTrackUK/Resources/NationalRailMap.json`: stations, operator colours,
  CRS identities, routed geographical sections, attribution and SHA-256 hashes
  of the PDF, catalogue and railway graph inputs.
- `TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json`: reference vectors,
  station/label targets, existing TfL semantic paths, river and cable-car anchors.
- `TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailStations.json`:
  additional CRS mappings for departure requests.

`routes.json` records physical corridors visible in the reference; its via
stations are routing constraints, not timetable stopping patterns. Operator
colours and network line styles come from the PDF. Geographical routes use
TrainTrack UK's OSM graph and the existing weighted railway router. Missing
routes and implausible detours fail generation; there is no straight-line fallback.

`platform_anchors.py` supplements sparse platform anchors by splitting existing
OSM edges at reviewed stations. Lea Bridge's catalogue coordinate is corrected
against TfL stop `910GLEABDGE`; no additional railway geometry is invented.
`paper_routes.py` follows the reference's coloured vector tracks and repairs
short gaps under interchange symbols. `landmarks.py` contains reviewed overlay
positions in this alternate diagram. Ambiguous station labels have explicit
anchor overrides in `build.py`.

The PDF crop and legend coordinates are specific to April 2026. A new revision
requires a visual review, station/segment coverage checks, routing checks and
light/dark rendering tests before replacing these bundled assets. Retain source
attribution and observe the reference publisher's map licensing terms.

The optional stations participate in map search and live departures. They are
excluded from the TfL journey-planner picker because their local `nr:CRS`
identities are not TfL journey endpoint IDs. No National Rail train positions
or timetable stopping patterns are inferred from the route layer.
