# Beck Map Implementation Plan

## Outcome

Build the Beck view as a separate, data-driven map renderer. Keep the existing
`Map` screen available during comparison, but do not reuse its runtime geometry
engine. Reuse only the app's semantic network IDs and live presentation state.

The renderer's contract is:

> Geometry is immutable and versioned. Selection, disruptions, closures and
> engineering works change presentation state only.

## Source assessment

- The attached 1614 x 975 outline is a useful visual-language reference, but it
  omits labels and most stations. It is not suitable as canonical geometry.
- `design_brief/map/standard-tube-map.pdf` is the best visual reference present
  in the repository. It is a two-page TfL Illustrator PDF dated April 2026, but
  it is encrypted against copying and explicitly limits online use to personal
  use. A TfL map licence and a permitted vector source/export are required
  before a faithful derived map can be distributed.
- `TubeGraph.json` remains the topology and live-data keyspace: 272 stations,
  378 line-specific adjacent-station segments and 11 Underground lines. Its
  schematic coordinates are a prototype seed only, not the fidelity baseline.

## Architecture

### Authored geometry document

Use a versioned Beck document with distinct types for:

- stations and logical interchange places;
- station-to-station sections keyed to stable `TubeSegment.id` values;
- explicit move, line and cubic path commands;
- shared corridor spines with authored per-line transforms or compiled paths;
- explicit station/interchange glyph primitives;
- manually positioned labels, including anchor, line breaks and rotation;
- draw order, crossing knockouts and style tokens;
- topology routes and a validated topology-to-artwork crosswalk.

The future bundled layout should live under `Resources/BeckMap/<version>/` and
be decoded independently from `TubeAppState.start()`. A bad artwork asset must
not prevent the offline graph or live TfL services from starting.

### Renderer

Use a SwiftUI `Canvas` for deterministic, immediate-mode vector drawing. Cache
paths and bounds once, then render in fixed passes:

1. background and non-interactive artwork;
2. route base strokes and crossing knockouts;
3. line muting and operational overlays;
4. selected or affected sections;
5. station and interchange glyphs;
6. manually positioned labels;
7. trains and transient focus indicators.

The camera owns only aspect-fit, scale and translation. It must never alter or
reflow geometry. Tap hit-testing inverse-transforms the screen point and selects
the nearest authored station or section. Canvas content needs a separate
accessible representation because Canvas does not expose individual elements
to assistive technologies automatically.

### Presentation state

Resolve existing app state into immutable section appearances:

- whole-line selection or greying by `TubeLineID`;
- exact affected sections from `activeAffectedSegmentIDs`;
- selected station and line emphasis;
- planned-work focus through the existing `focus(on:in:)` flow;
- later: closure, delay and work patterns that do not rely on colour alone.

Named-station ranges must include a line ID and, when a route branches or loops,
an explicit route/branch choice. The result is a set of stable segment IDs; no
path geometry is generated or changed.

## Delivery phases

### 0. Parallel shell and retired generated prototype

- Add a fifth `Beck` tab and a separate Canvas renderer.
- The initial graph-seeded adapter proved the interaction seam but repeated the
  old Map screen's runtime-layout failure. It has been deleted and the runtime
  repository now refuses documents marked as prototype geometry.
- Keep the existing Map tab available for comparison without allowing its
  geometry pipeline to enter Beck.

### 1. Rights and source lock

- Confirm intended distribution and obtain the required TfL map/brand licence.
- Obtain a permitted, date-stamped vector master for one agreed map revision.
- Freeze the first release scope: 11 Underground lines only, or the full rail
  map including DLR, Elizabeth line, Overground and Trams.
- Confirm typography licensing or approve a substitute.

### 2. Golden slices and toolchain

- Start with an authored Heathrow slice to prove the Terminal 4 loop, Terminal
  5 branch, route ambiguity, curves, manual labels and independently
  addressable station-to-station sections.
- Follow with a representative central-London slice containing a shared
  corridor, crossing, ordinary station and major interchange.
- Build the offline compiler, schema validator, topology crosswalk and visual
  reference overlay/difference view.
- Prove independent line greying and named-section highlighting in a shared
  corridor before tracing the whole network.

Current progress:

- The Heathrow slice is complete and trace-verified against its supplied
  reference crop.
- The central-backbone slice is complete from Paddington and Baker Street
  through King's Cross, Farringdon/Moorgate, Bank/Monument and London Bridge.
  It proves explicit platform ports at complex interchanges, authored ordinary
  station ticks, parallel Circle/Hammersmith & City/Metropolitan lanes, and
  independently addressable Northern, District and Waterloo & City sections.
- The west-connector slice is complete from Hounslow West through Acton Town,
  Hammersmith and Earl's Court to South Kensington and Green Park. Its 27
  station-pair sections prove that overlapping Piccadilly, District and Circle
  corridors remain independently addressable, including complex interchange
  ports at Acton Town, Hammersmith, Earl's Court, Gloucester Road and South
  Kensington.
- Debug builds can switch between all three slices and overlay the corresponding
  official reference at 40% geometry opacity. All reference rasters are
  excluded from Release builds.

### 3. Full authored map

- Extract/trace every in-scope route section, station port, interchange, label,
  crossing and special topology from the licensed master.
- Validate that every displayed coloured route pixel belongs to an addressable
  section; no decorative or connector track may be operationally anonymous.
- Version the source and compiled geometry without overwriting prior releases.

### 4. Live integration and accessibility

- Connect disruptions, engineering works, selection and live trains through
  the topology crosswalk.
- Add a searchable station browser and VoiceOver station actions as gesture
  alternatives.
- Respect Dynamic Type, Reduce Motion, light/dark app chrome and colour-blind
  status communication. Treat the official light artwork as the fidelity
  baseline; any dark map theme is a separate derived design.

### 5. Quality gate and promotion

- Add schema, topology, camera, range-resolution and accessibility tests.
- Add fixed-device snapshots for normal, selected, disrupted and planned-work
  states plus Heathrow, Northern branches, Circle and shared corridors.
- Define visual tolerances only after fixing render size, scale, crop, colour
  profile, font and antialiasing environment.
- Run Beck and Map side by side until Beck passes visual and interaction review,
  then decide whether to make Beck the default and retire Map.

## Acceptance criteria

- The renderer performs no layout, label placement, smoothing or corridor
  inference at runtime.
- Every station and visible route section has a stable ID and valid topology
  crosswalk.
- Whole lines and exact named sections can be muted, highlighted or marked
  closed without modifying geometry.
- Shared corridor peers remain independently styleable.
- Pan, pinch, reset, selection and station detail work on iPhone.
- VoiceOver can discover stations and the same information is available through
  a searchable non-map interface.
- The licensed full-map render passes deterministic snapshot and visual
  comparison checks against the agreed source revision.

## Decisions required before fidelity work

1. Is the first release Underground-only or the complete current TfL rail map?
2. Is the app intended for public/commercial distribution, and what TfL map,
   brand and font rights have been secured?
3. Which exact dated TfL vector revision is the acceptance master?
4. Should closures replace line colour with grey, overlay it with a patterned
   treatment, or use both according to incident type?
