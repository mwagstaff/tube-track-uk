# TubeTrack UK — Codex Product & Implementation Brief

## 1. Objective

Build a standalone native iOS application named **TubeTrack UK**, developed by **SkyNoLimit**, focused on visualising the London Underground network, live service disruption, live/estimated train movement, and future engineering works.

The app should feel visually related to **TrainTrack UK**, while being purpose-built for the Tube rather than reusing the railway UI directly.

The core product goals are:

1. Make the Tube map the primary interface rather than a secondary reference.
2. Provide an immediately understandable visual indication of live service disruption.
3. Allow users to switch between:
   - a classic **Harry Beck-style schematic Tube map**
   - a **real-world geographic MapKit view**
4. Show live trains moving across either map when enabled.
5. Provide a chronological future engineering-works view.
6. Use modern native iOS UI patterns, with **Liquid Glass / translucent floating panels** where appropriate.
7. Prefer authoritative TfL open data and make all source attribution clear.
8. Keep the architecture observable and debuggable. Do not silently guess when TfL data is incomplete.

---

# 2. Target Platform

Initial target:

- iPhone
- native Swift / SwiftUI
- current production iOS SDK supported by the existing SkyNoLimit development environment
- MapKit for the geographic view
- async/await networking
- Codable data models
- native SwiftUI navigation and sheets/popovers where practical

Design the data layer so iPad support can be added later without rewriting the application.

The layout should already adapt intelligently to larger widths.

---

# 3. Primary Navigation

Use a compact native tab bar with four destinations:

1. **Map**
2. **Real World**
3. **Works**
4. **About**

Suggested SF Symbols:

```text
Map         map
Real World  globe.europe.africa
Works       wrench.and.screwdriver
About       info.circle
```

The Map and Real World screens are the primary experiences.

Do not bury them in menus.

---

# 4. Data Sources

## 4.1 Transport for London Unified API

Use the official TfL Unified API for current Tube data.

Base:

```text
https://api.tfl.gov.uk
```

Pass the TfL application key as required by current TfL API policy.

Do not hard-code secrets in the application source repository.

Use an environment/configuration abstraction.

### Live line status

Primary endpoint family:

```text
GET /Line/Mode/tube/Status
```

and/or appropriate line-specific status endpoints.

Retain the complete status object rather than immediately flattening it into a single string.

Important fields/semantic concepts to preserve include:

- line ID
- line name
- status severity
- status severity description
- reason
- validity periods
- disruption details
- affected routes / sections if provided
- affected stops if provided

Codex should inspect the actual current TfL response schema and create typed Swift models around the fields genuinely returned.

Do not invent missing structured disruption geometry.

---

## 4.2 Future service status

TfL exposes date-range line-status endpoints such as:

```text
GET /Line/{lineId}/Status/{startDate}/to/{endDate}?detail=true
```

Use these as a source for future disruption when data is available.

### Important caveat

Do **not** assume that all engineering work published by TfL months in advance will immediately exist in the Unified API.

TfL has stated publicly that Tube/rail engineering works can be loaded into the status API in batches.

Therefore the Works screen needs a layered ingestion strategy.

---

## 4.3 Tube This Weekend feed

TfL publishes a **Tube This Weekend** dataset containing planned line and station closures for the coming weekend, including some station-access works such as lift and escalator work.

Use it as an additional high-confidence near-term engineering-work source.

The backend/data layer should normalise it into the same internal `EngineeringWork` model used for future status.

---

## 4.4 Longer-range planned works

For engineering works further ahead than the reliable API ingestion horizon:

1. Investigate TfL's currently published planned-closure / look-ahead data.
2. Prefer a machine-readable official TfL feed if currently available.
3. If the only authoritative long-range source is a TfL published document/page, implement ingestion **server-side/build-time**, not by scraping arbitrary HTML in the iOS client.
4. Record:
   - source
   - retrieval timestamp
   - TfL publication/update timestamp where available
   - confidence/source type
5. Once the same disruption becomes available through the Unified API, prefer the structured API representation.

The app must not pretend long-range data has the same freshness as live status.

---

# 5. Tube Network Geometry

The app needs two different representations of the same logical Tube network.

## 5.1 Schematic Tube map geometry

The default Map screen must use a custom schematic dataset inspired by the classic Harry Beck map.

Requirements:

- straight horizontal, vertical and 45-degree diagonal sections
- recognisable station topology
- interchange stations
- correct line connectivity
- central London spacing optimised for readability rather than geography
- high-quality vector rendering at all zoom levels
- no raster map image as the primary implementation

Store topology separately from display geometry.

Suggested conceptual model:

```swift
struct TubeStation {
    let id: String
    let name: String
    let naptanId: String?
    let latitude: Double
    let longitude: Double
    let schematicPoint: CGPoint
    let lineIDs: Set<String>
    let interchange: Bool
}

struct TubeLineSegment {
    let id: String
    let lineID: String
    let fromStationID: String
    let toStationID: String
    let schematicPath: [CGPoint]
    let geographicPath: [CLLocationCoordinate2D]
}
```

The key architectural concept is:

> A service disruption should resolve to **network segments**, not merely to an entire Tube line whenever enough information exists.

That enables section-by-section visual highlighting.

---

## 5.2 Geographic Tube geometry

The Real World view should follow the same principle used in the attached TrainTrack UK railway-routing plan:

> operational data describes what the service is doing; network geometry describes where the infrastructure physically runs.

The existing TrainTrack plan explicitly separates service data from geometry, constructs continuous route polylines, renders them in MapKit, and interpolates train positions by distance along the routed polyline rather than drawing straight station-to-station shortcuts. Use the same conceptual approach for TubeTrack.

For TubeTrack this should be simpler than National Rail because the Underground network is finite and relatively stable.

Preferred approach:

1. Obtain an authoritative or suitably licensed geographic Tube track/network geometry dataset.
2. Pre-process it outside the iOS runtime.
3. Build line-specific ordered network segments.
4. Associate each segment with its two endpoint stations.
5. Store a compact prebuilt representation for the app or backend.
6. Render the geometry using MapKit polylines.

Do not calculate arbitrary geographic routing on-device on every launch.

Do not substitute straight lines between station latitude/longitude coordinates unless explicitly falling back because no better geometry exists.

---

# 6. Standard Tube Line Colours

Create a central colour registry.

Do not duplicate colour literals throughout the UI.

Use TfL-standard colours/current branding guidance.

Conceptual model:

```swift
enum TubeLineID: String, Codable, CaseIterable {
    case bakerloo
    case central
    case circle
    case district
    case hammersmithCity
    case jubilee
    case metropolitan
    case northern
    case piccadilly
    case victoria
    case waterlooCity
}
```

Provide:

```swift
TubeLineStyle.colour(for:)
TubeLineStyle.displayName(for:)
TubeLineStyle.accessibleForeground(for:)
```

Use line colours consistently across:

- schematic map
- real-world map
- status cards
- engineering works
- filters
- train markers
- line chips

---

# 7. Screen 1 — Schematic Tube Map

## 7.1 Default state

This is the opening screen.

On first launch:

- show the full London Underground schematic
- zoomed into **central London**
- use normal standard Tube line colours
- show station names at an appropriate density for the current zoom
- present a translucent floating **Live Status** panel by default
- status panel should not permanently obscure important map content
- panel may be collapsed by the user
- preserve the user's collapsed/expanded preference

Top navigation should be minimal.

Suggested top glass controls:

```text
[ TubeTrack UK ]                 [filters] [location/options]
```

Do not clutter the map with a conventional large navigation bar.

---

## 7.2 Map gestures

Support:

- pinch to zoom
- pan
- double tap / native zoom affordances if appropriate
- tap station
- tap line
- tap live train
- tap disrupted line segment

Keep line thickness visually stable enough to remain usable across scale changes.

Station labels should progressively reveal as the user zooms.

---

# 8. Disruption Highlight Mode

This is one of the app's defining features.

Provide a prominent but elegant control such as:

```text
[ Normal ] [ Issues ]
```

or a single Liquid Glass toggle:

```text
⚠︎ Highlight issues
```

## 8.1 Normal mode

- every Tube line uses its standard colour
- normal station presentation
- disruptions remain visible in the side status panel

## 8.2 Highlight Issues mode

When enabled:

- **all unaffected Tube line segments become grey/desaturated**
- affected line segments remain in their standard Tube colours
- affected stations remain prominent
- relevant station labels remain visible
- unrelated station labels should become lower contrast
- interchange nodes should remain understandable
- do not hide unaffected topology completely

The intended visual hierarchy is:

```text
Affected infrastructure       100% normal line colour
Affected station/interchange  prominent
Unrelated network             neutral translucent grey
Map labels not involved       reduced prominence
```

---

## 8.3 Section-level highlighting

Do not colour an entire line as affected simply because TfL says there is a problem somewhere on it if a narrower affected section can be derived reliably.

Example:

```text
Northern line
No service between Camden Town and Edgware
```

Desired display:

- Camden Town → Edgware Northern line branches: black/prominent
- remaining Northern line: grey
- all other lines: grey
- relevant station names: prominent
- disruption card uses Northern line identity

Build a disruption-to-network resolver.

Conceptual output:

```swift
struct ResolvedDisruption {
    let disruptionID: String
    let lineIDs: Set<String>
    let affectedStationIDs: Set<String>
    let affectedSegmentIDs: Set<String>
    let resolutionConfidence: ResolutionConfidence
}
```

Suggested confidence:

```swift
enum ResolutionConfidence {
    case exact
    case inferred
    case lineOnly
}
```

If TfL only provides line-level text and the affected section cannot safely be derived, highlight the whole line rather than hallucinating a section.

---

# 9. Live Status Panel

Show this by default on both map screens.

On iPhone use a floating Liquid Glass card positioned to feel like a side panel without making the map unusable.

Possible behaviour:

- landscape / wide layout: right-side panel
- portrait: trailing floating card or compact bottom/trailing panel
- draggable/collapsible only if the implementation remains intuitive
- do not require opening a modal just to see status

Header:

```text
Live Status                       Updated now
```

If everything is running normally:

```text
✓ Good service on all Tube lines
```

If issues exist, show cards ordered roughly by severity.

Example:

```text
[Northern colour bar]
Northern
Severe delays

Severe delays due to an earlier signal failure at Camden Town.
```

Each card can be tapped to:

1. activate/highlight that disruption on the map
2. zoom the map to its affected section where confidently known
3. optionally expand additional detail

Add a small:

```text
Show all issues
```

control where necessary.

---

# 10. Station Interaction

Tapping a station should display a compact Liquid Glass detail card.

Minimum:

```text
Oxford Circus
Central • Bakerloo • Victoria

Live departures >
Station status >
```

If the station itself is affected:

```text
⚠ Station issue
Entry only due to ...
```

Do not overbuild station detail in the first version.

---

# 11. Line Interaction

Tapping a line should allow a temporary focus mode.

Example:

```text
Victoria line
Good service
```

Actions:

- Focus line
- Show trains on this line
- View line status

When focused, other lines can become muted.

---

# 12. Live Train Visualisation

Both map views require an option to show moving Tube trains.

This is optional/off by default if enabling it creates significant visual noise or API load.

Control:

```text
🚇 Live trains
```

When enabled, expose optional line filters.

Example floating filter:

```text
Live trains
[All] [Central] [Victoria] [Northern] ...
```

Use horizontally scrolling line chips.

---

# 13. TfL Train Data Strategy

Use TfL live Tube prediction data from the Unified API.

Relevant API family includes line arrivals/predictions such as:

```text
GET /Line/{lineId}/Arrivals
```

TfL prediction objects can contain values such as:

- vehicle ID
- line ID
- station
- platform
- direction
- destination
- expected arrival
- time to station
- current location text

Do not assume TfL provides a continuously updated GPS latitude/longitude for every Tube train.

The goal is therefore:

> estimate a visually plausible train position using TfL's live predictions plus known Tube track geometry.

This should be explicitly presented internally as an estimated position where appropriate.

---

# 14. Train Position Resolver

Use the same core principle as the attached TrainTrack UK route implementation: interpolate by **distance along the actual route polyline**, not by straight-line geographic interpolation between station centres.

For each live train:

1. identify stable `vehicleId`
2. identify line
3. identify direction
4. infer the train's current/next station relationship from available TfL prediction data
5. identify the corresponding network segment
6. estimate progress through the segment
7. interpolate distance along that segment's polyline
8. calculate bearing from local geometry
9. animate smoothly between refreshed estimates

Conceptual model:

```swift
struct LiveTubeTrain {
    let vehicleID: String
    let lineID: String
    let destination: String?
    let direction: String?
    let previousStationID: String?
    let nextStationID: String?
    let progress: Double?
    let coordinate: CLLocationCoordinate2D?
    let schematicPoint: CGPoint?
    let bearing: Double?
    let lastUpdated: Date
    let estimated: Bool
}
```

---

# 15. Train Animation

TfL feeds update discretely.

Do not make train icons jump every refresh.

Implement local animation:

```text
API estimate A
     |
     | smooth interpolation
     v
API estimate B
```

Requirements:

- smoothly animate between known estimates
- cap/sanity-check impossible jumps
- fade/remove stale vehicles
- do not move through station topology impossible for that line
- reset when a vehicle changes direction/working
- stop animation when data becomes stale

Use a modest train marker.

Avoid showing hundreds of giant icons.

At wide zoom:

- show small moving dots/line-coloured indicators

At close zoom:

- optionally show a small train glyph

Train marker colours should correspond to line identity but maintain contrast on the matching route.

---

# 16. Train Filtering

When live trains are enabled, users can choose:

```text
All lines
Bakerloo
Central
Circle
District
Hammersmith & City
Jubilee
Metropolitan
Northern
Piccadilly
Victoria
Waterloo & City
```

Use line-coloured chips.

Support multiple selected lines if easy.

If multi-select adds too much first-version complexity, use:

```text
All
or one specific line
```

for MVP.

---

# 17. Screen 2 — Real World Map

Use Apple MapKit.

Default camera:

- central London
- enough scale to see the core Tube network
- standard cartographic map underneath
- Tube railway geometry overlaid as coloured polylines
- Tube stations shown using lightweight station markers

Aim for an elegant balance; the Tube overlay should visually dominate sufficiently without completely hiding streets/geography.

---

# 18. Real World Map Controls

Match the schematic map's controls wherever possible:

- Highlight issues
- Live trains
- Line filter
- status panel
- station tap
- line tap

Users should not have to learn two different interfaces.

Use the same data/view models for:

```text
Current status
Resolved disruptions
Live trains
Selected line
Selected disruption
```

Only the renderer differs.

---

# 19. Relationship to TrainTrack UK Real-World Routing

Use the attached **TrainTrack UK – OSM Railway Routing Prototype Plan** as the architectural reference for geographic rendering.

Important reusable concepts from that design:

- separate operational/service data from physical network geometry
- use precomputed network geometry rather than calculating large graph routes in the iOS UI
- represent routes as continuous polylines
- associate stations with locations along those polylines
- interpolate train positions by distance along route geometry
- cache/precompute stable geometry
- make diagnostics explicit
- never silently hide geometry/routing failures

TubeTrack does **not** need to reuse the entire National Rail OSM A* pipeline if an accurate prebuilt Tube network dataset can be generated more directly.

The desired result, not the exact implementation, is shared.

---

# 20. Geographic Disruption Highlight Mode

The same rule as schematic mode:

### Normal

All Tube lines use standard colours.

### Issues

- affected geographic track segments retain their line colours
- unaffected track segments become neutral grey
- affected stations remain visually prominent
- non-affected station markers reduce contrast

MapKit base-map colour should not overpower the highlighted lines.

---

# 21. Screen 3 — Future Engineering Works

Create a dedicated Works tab.

Purpose:

> Give the user a beautiful, scannable chronological list of upcoming planned Tube closures and engineering work.

Default sort:

```text
Soonest first
```

Group by date/weekend.

Example:

```text
THIS WEEKEND
22–23 August

[Northern line colour strip]
Northern line
Part closure

No service between ...
Saturday 22 Aug – Sunday 23 Aug


29–31 AUGUST

[District line colour strip]
District line
Part closure
...
```

---

# 22. Engineering Work Card Design

Use modern translucent cards.

Each item should display:

- start date
- end date
- line
- line colour
- disruption title/status
- human-readable description
- affected stations/section if known
- source freshness/update time where useful
- source confidence if needed internally

For multiple affected lines:

- show multiple line-colour pills/stripes
- do not pick an arbitrary single colour

Tap expands into detail.

Detail can optionally include:

```text
View on schematic map
View on real-world map
```

which opens the corresponding map and highlights the affected infrastructure.

---

# 23. Engineering Work Filtering

Add a lightweight filter button.

Options:

```text
All lines
Selected line(s)
This weekend
Next 30 days
```

Do not make filters dominate the screen.

Line filters should use standard colours.

Persist last-used filter only if doing so feels natural; default should remain useful to a first-time user.

---

# 24. Engineering Work Data Model

Suggested internal normalised model:

```swift
struct EngineeringWork: Identifiable, Codable {
    let id: String

    let title: String
    let description: String

    let lineIDs: [String]
    let affectedStationIDs: [String]
    let affectedSegmentIDs: [String]

    let startDate: Date
    let endDate: Date

    let source: EngineeringWorkSource
    let sourceUpdatedAt: Date?
    let fetchedAt: Date

    let resolutionConfidence: ResolutionConfidence
}

enum EngineeringWorkSource: String, Codable {
    case unifiedAPI
    case tubeThisWeekend
    case tflLongRange
}
```

Deduplicate overlapping records from multiple TfL sources.

Prefer the freshest/most structured source.

Retain source provenance for diagnostics.

---

# 25. Screen 4 — About

Keep this intentionally simple and polished.

Header:

```text
TubeTrack UK
```

Optional short description:

```text
A modern live view of the London Underground.
```

Sections:

## Developer

```text
SkyNoLimit
https://skynolimit.dev
```

Use a tappable external link.

## Data

```text
Transport for London
Live Tube status, predictions, stations and planned works.
```

Required attribution should follow current TfL open-data/branding terms.

Include wording along the lines required by TfL, currently including:

```text
Data provided by Transport for London
```

and/or the specific attribution required for the relevant feed.

## Mapping

If OpenStreetMap data is used for any geographic geometry:

```text
© OpenStreetMap contributors
```

If only MapKit base mapping is used, retain Apple's normal MapKit attribution and do not obscure it.

## Disclaimer

Make clear TubeTrack UK is an independent app and not an official Transport for London application.

Suggested wording:

```text
TubeTrack UK is an independent application developed by SkyNoLimit and is not affiliated with or endorsed by Transport for London.
```

Check final wording against current TfL terms before App Store release.

## Version

Display:

```text
Version x.y (build z)
```

---

# 26. Liquid Glass Visual Direction

The app should look like a high-quality modern iOS app rather than a TfL web page wrapped in SwiftUI.

Use Liquid Glass selectively.

Ideal uses:

- floating status panel
- map controls
- filter pills
- selected station card
- selected train card
- engineering works cards
- compact navigation chrome

Avoid turning every surface into a blurred translucent rectangle.

The Tube map itself must remain the visual hero.

---

# 27. Visual Style

Desired characteristics:

- spacious
- crisp
- premium
- playful enough to suit the Tube colours
- not cartoonish
- strong information hierarchy
- excellent accessibility
- smooth animation
- restrained shadows
- rounded glass panels
- subtle material blur
- minimal borders
- strong use of line colours as data, not decoration

Use SF Pro / system typography.

Do not imitate TfL's official app closely enough to create confusion about affiliation.

---

# 28. Accessibility

Requirements:

- VoiceOver labels for stations, train markers and status controls
- Dynamic Type where practical outside dense map labels
- do not use colour alone to communicate status
- use warning/status icons and textual descriptions
- sufficient contrast in greyed-out issue mode
- Reduce Motion support for live-train animation
- increased contrast support where reasonable
- minimum sensible tap areas

---

# 29. App State Architecture

Suggested observable app state:

```swift
@Observable
final class TubeAppState {
    var selectedTab: AppTab

    var mapMode: TubeMapMode
    var disruptionDisplayMode: DisruptionDisplayMode

    var liveStatus: [TubeLineStatus]
    var resolvedDisruptions: [ResolvedDisruption]

    var showLiveTrains: Bool
    var trainLineFilter: Set<String>
    var liveTrains: [LiveTubeTrain]

    var selectedStationID: String?
    var selectedLineID: String?
    var selectedDisruptionID: String?
}
```

Prefer small specialised services rather than one giant API manager.

---

# 30. Suggested Services

```text
TfLClient
TubeNetworkRepository
TubeStatusService
DisruptionResolver
EngineeringWorksService
TubeTrainPredictionService
TrainPositionResolver
SchematicMapRepository
GeographicMapRepository
```

### TfLClient

Responsible only for:

- HTTP
- authentication/key
- decoding
- retry/backoff
- errors
- caching headers where applicable

### DisruptionResolver

Responsible for:

```text
TfL disruption
       ↓
affected line/station text/data
       ↓
known Tube topology
       ↓
resolved affected station + segment IDs
```

### TrainPositionResolver

Responsible for:

```text
TfL predictions
       ↓
train identity/direction/next stop
       ↓
Tube topology/geometry
       ↓
estimated progress
       ↓
schematic + geographic coordinates
```

---

# 31. Refresh Strategy

Use a sensible refresh cadence.

TfL describes Tube prediction/status data as fast-changing.

Do not hammer the API for every SwiftUI redraw.

Suggested design:

### Line status

Refresh periodically while app is active.

Example target:

```text
30 seconds
```

subject to TfL limits/current API guidance.

### Trains

When Live Trains is enabled:

```text
approximately every 15–30 seconds
```

then animate smoothly locally.

Do not issue one request per visible train.

Prefer line-level batched prediction retrieval.

Stop/highly reduce polling when:

- app is backgrounded
- live trains are disabled
- relevant view is not active

---

# 32. Caching

Cache:

- network topology
- schematic geometry
- geographic geometry
- station metadata
- line metadata
- engineering works
- last-known status

Do not make the app unusable during a temporary TfL outage.

On stale cached data, clearly show something such as:

```text
Status last updated 12 min ago
```

Never present stale live information as current.

---

# 33. Error Handling

Explicitly support:

- TfL API unavailable
- rate limited
- malformed/missing prediction fields
- disruption reason without structured affected stations
- unknown station names
- long-range works source unavailable
- train vehicle disappearing
- prediction sequence inconsistent
- geometry mapping failure

Map should still render its static network when live APIs fail.

---

# 34. Diagnostics

Add DEBUG-only diagnostics.

Examples:

```text
Disruption:
Northern line
Reason: No service Camden Town–Edgware
Parsed stations: Camden Town, Edgware
Segments resolved: 14
Confidence: exact
```

and:

```text
Train:
vehicleId: 214
line: victoria
direction: southbound
nextStation: Oxford Circus
segment: Warren Street -> Oxford Circus
progress: 0.61
position source: prediction interpolation
```

Unknown/failed resolutions should be visible in developer logs rather than silently ignored.

---

# 35. Analytics / Privacy

For MVP, no analytics are required unless the existing SkyNoLimit app template already includes privacy-respecting analytics.

Do not require:

- user account
- sign-in
- location permission

unless a future feature genuinely needs it.

Map viewing and status information should work anonymously.

---

# 36. Suggested Project Structure

```text
TubeTrackUK/
├── App/
│   ├── TubeTrackUKApp.swift
│   └── TubeAppState.swift
├── Models/
│   ├── TubeLine.swift
│   ├── TubeStation.swift
│   ├── TubeLineSegment.swift
│   ├── TubeLineStatus.swift
│   ├── ResolvedDisruption.swift
│   ├── EngineeringWork.swift
│   └── LiveTubeTrain.swift
├── Networking/
│   ├── TfLClient.swift
│   └── TfLEndpoints.swift
├── Services/
│   ├── TubeStatusService.swift
│   ├── DisruptionResolver.swift
│   ├── EngineeringWorksService.swift
│   ├── TubeTrainPredictionService.swift
│   └── TrainPositionResolver.swift
├── Network/
│   ├── TubeNetworkRepository.swift
│   ├── SchematicNetwork.json
│   └── GeographicNetwork.json
├── Features/
│   ├── SchematicMap/
│   ├── RealWorldMap/
│   ├── Works/
│   └── About/
├── Components/
│   ├── GlassPanel.swift
│   ├── LineChip.swift
│   ├── StatusCard.swift
│   └── TubeTrainMarker.swift
└── Resources/
```

Treat this as guidance rather than an inflexible requirement.

---

# 37. Recommended Implementation Phases

## Phase 1 — Static Tube network

Deliver:

- app shell
- four tabs
- custom schematic map
- correct standard line colours
- central-London default viewport
- pan/zoom
- station labels/interchanges

No live data yet.

Success criterion:

> The schematic network looks polished enough to be the app's primary screen.

---

## Phase 2 — Live line status

Integrate TfL status.

Deliver:

- status panel
- normal / issue-highlight mode
- line-level disruption highlighting
- last-updated state
- API errors/stale data

---

## Phase 3 — Segment disruption resolution

Deliver:

- line topology model
- station-name mapping
- affected segment resolver
- section-level highlighting
- tap disruption → focus affected section

Do not attempt fragile NLP over every possible English sentence in one pass.

Start with common TfL patterns such as:

```text
No service between X and Y
Part suspended between X and Y
Severe delays between X and Y
No service X to Y
```

Use known station aliases.

If parsing fails:

```text
resolutionConfidence = .lineOnly
```

---

## Phase 4 — Real World Map

Deliver:

- MapKit
- geographic Tube network
- stations
- same live status panel
- same issue-highlight semantics
- map selection/focus behaviour

Reuse existing TrainTrack UK mapping principles where sensible.

---

## Phase 5 — Engineering works

Deliver:

- future status data
- Tube This Weekend ingestion
- longer-range official TfL source investigation/normalisation
- chronological Works screen
- line colours
- filters
- map deep links

---

## Phase 6 — Live trains

Start with **one line** for proof of concept, preferably a relatively straightforward line.

Deliver:

- line predictions
- stable vehicle tracking
- topology mapping
- schematic position estimation
- geographic position estimation
- animation
- stale-train removal

Once robust, enable all lines.

---

## Phase 7 — Polish

Deliver:

- Liquid Glass materials
- animation refinement
- accessibility
- caching
- offline/stale state
- performance
- App Store attribution
- icon/branding
- screenshots

---

# 38. Performance Requirements

The schematic map must feel native.

Target:

- fluid pan/zoom
- no reconstruction of the entire network every frame
- no network request caused by map movement
- efficient path rendering
- efficient label culling
- live train animation that does not trigger expensive whole-map redraws

Precompute paths where possible.

Consider Canvas or an efficient vector rendering layer if a naïve stack of SwiftUI Shapes performs poorly.

---

# 39. Schematic Label Strategy

Central London is dense.

Implement label decluttering.

Suggested levels:

### Far zoom

Only major interchange names.

### Medium zoom

Major stations + selected surrounding stations.

### Near zoom

All station names where practical.

Always display:

- selected station
- station involved in selected disruption
- termini relevant to selected line/issue

Do not allow labels to make the network unreadable.

---

# 40. Default Camera / Viewport

Opening schematic:

```text
Central London focus
```

Aim to include approximately the Zone 1 core rather than the entire Underground network.

Provide a small native control to:

```text
Fit network
```

and, after the user has panned:

```text
Return to central London
```

Do not request user location for this.

---

# 41. Map Selection Behaviour

When the user taps a disruption in the status panel:

1. enable issue highlighting if not already enabled
2. select the disruption
3. focus the affected map section where known
4. leave enough context around the affected section
5. show a compact detail card

When cleared:

- preserve issue mode if the user enabled it manually
- otherwise return to prior state

---

# 42. Visual Mock-Up Guidance — Screen 1

The supplied mock-up for Codex should be interpreted as follows:

### Schematic map

- cream/very light neutral map canvas
- highly polished Harry Beck-inspired lines
- central London framing
- line colours vivid
- station circles clean and small
- key interchange names visible

### Top floating controls

Liquid Glass pill(s):

```text
TubeTrack UK                 ⚠ Issues    🚇 Trains
```

### Status panel

Floating translucent card on right/trailing side:

```text
Live Status
Updated now

Northern
Severe delays
...

Piccadilly
Minor delays
...
```

Use line-coloured vertical accents.

---

# 43. Visual Mock-Up Guidance — Screen 2

### Base

Apple MapKit real-world London map.

### Overlay

Accurate Tube routes following geographic railway alignment.

### Controls

Same controls/positions as schematic where possible.

### Status

Same glass panel.

### Trains

Small moving line-coloured train markers.

The UI should instantly communicate:

> this is the same network/data as the schematic view, rendered geographically.

---

# 44. Visual Mock-Up Guidance — Screen 3

Engineering Works:

- large title `Engineering Works`
- understated subtitle such as `Planned closures and service changes`
- small glass filter button
- chronological date sections
- glass cards
- coloured line edge/pill
- affected section in bold
- dates clearly visible
- enough whitespace to scan rapidly

Do not use a dense table.

---

# 45. Visual Mock-Up Guidance — Screen 4

About:

- subtle TubeTrack UK identity/header
- elegant icon area
- simple grouped Liquid Glass cards:
  - Developer
  - Data Sources
  - Mapping & Attribution
  - Version
- external-link chevrons/icons where appropriate

Keep it calm and minimal.

---

# 46. MVP Acceptance Criteria

The first genuinely useful release must:

1. Launch directly into a polished schematic Tube map.
2. Default to a central-London viewport.
3. Render every Tube line in its standard colour.
4. Show live TfL line status.
5. Display live problems in an always-available status panel.
6. Provide issue-highlight mode.
7. Grey unrelated Tube infrastructure in issue-highlight mode.
8. Highlight affected sections rather than whole lines whenever this can be resolved confidently.
9. Provide a MapKit real-world view.
10. Apply identical disruption semantics to the geographic view.
11. List future engineering works chronologically.
12. Clearly associate works with line colours.
13. Provide developer and TfL attribution.
14. Remain usable when live TfL APIs temporarily fail.

---

# 47. Live Train Acceptance Criteria

Live trains are complete when:

1. User can enable/disable them.
2. User can filter them by Tube line.
3. The app uses TfL live prediction data rather than arbitrary simulation.
4. Train identity is kept stable enough to animate.
5. Trains follow known Tube topology.
6. Schematic trains move along schematic line geometry.
7. Geographic trains move along geographic Tube geometry.
8. Movement between TfL updates is smoothly interpolated.
9. Stale trains disappear.
10. The UI does not claim precision greater than the source data supports.

---

# 48. Things Codex Must NOT Do

Do not:

- use a static Tube-map PNG as the main map implementation
- scrape Google Maps
- draw the Real World Tube network as naïve straight station-to-station chords where track geometry exists
- claim trains are GPS tracked if they are prediction/interpolation based
- highlight an invented affected section because a disruption reason was ambiguous
- hard-code API keys into Git
- make the UI look like an official TfL product
- obscure Apple MapKit attribution
- hide network/API parsing failures
- hammer TfL APIs
- require login
- make every screen a giant list of opaque cards
- use generic random colours instead of standard line colours

---

# 49. Testing

Add tests around the difficult logic.

## Disruption resolver

Examples:

```text
No service between Camden Town and Edgware
No service between Acton Town and Heathrow Terminal 5
Part suspended between Baker Street and Aldgate
```

Tests should verify:

- station resolution
- correct branch/segment traversal
- no accidental other branch
- ambiguous cases fall back safely

## Train resolver

Tests should cover:

- normal progression
- terminus turnaround
- branches
- stale vehicle
- missing prediction
- duplicated prediction
- direction change
- impossible jump

## Engineering works

Tests:

- deduplication
- chronological sorting
- multi-line works
- overlapping data from two TfL sources
- source freshness preference

---

# 50. Source / Licensing Checklist Before Release

Before App Store submission, Codex/developer must re-check the **current** TfL open-data terms and branding requirements.

At minimum the design should support:

```text
Data provided by Transport for London
```

The app must not imply official TfL affiliation.

If OpenStreetMap-derived geometry is used:

```text
© OpenStreetMap contributors
```

and comply with ODbL requirements.

---

# 51. Reference: Existing TrainTrack UK Route-Mapping Principle

The attached TrainTrack UK plan establishes an architecture where:

```text
service data
    +
physical railway geometry
    ↓
continuous route polyline
    ↓
distance-along-route station positions
    ↓
train interpolation
    ↓
MapKit
```

For TubeTrack UK use the corresponding principle:

```text
TfL topology/status/predictions
    +
Tube schematic + geographic geometry
    ↓
segment-aware Tube network
    ↓
disruption resolution
    +
train progress interpolation
    ↓
Schematic Map / MapKit
```

The Tube implementation should be simpler and more deterministic because its network can be prebuilt and versioned.

---

# 52. First Task for Codex

Start with a self-contained Phase 1 prototype before implementing live trains.

Build:

```text
TubeTrack UK
  ├─ schematic map
  ├─ pan/zoom
  ├─ standard Tube colours
  ├─ station nodes
  ├─ central London default viewport
  ├─ placeholder Liquid Glass status panel
  └─ four-tab navigation
```

Then integrate:

```text
GET https://api.tfl.gov.uk/Line/Mode/tube/Status
```

and prove:

1. status objects decode reliably
2. affected lines can be visually identified
3. `Highlight Issues` greys the unaffected network
4. tapping a status card selects/focuses the matching line

Only after that should Codex implement section-level disruption parsing and live-train interpolation.

---

# 53. Final Product Intent

TubeTrack UK should answer three questions almost instantly:

> **What is happening on the Tube right now?**

> **Where exactly is it happening?**

> **What is going to be closed later?**

The distinctive experience is not simply presenting TfL status text.

It is turning that data into a **beautiful, interactive visual network**, in both schematic and real-world form, with live trains and section-aware disruption highlighting.
