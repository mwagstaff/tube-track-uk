# TubeTrack UK – Real World Map Rendering Redesign

## Objective

Redesign the **Real World** map mode so that it behaves similarly to the Real World view in **TrainTrack UK**.

At present, the Underground lines are simply drawn as straight polylines between stations. This produces long, unrealistic diagonals that visibly cut across roads, buildings and parks.

Instead, the map should follow the **actual railway alignment** from OpenStreetMap wherever possible.

The end result should look like a live railway network overlaid onto Apple Maps / MapLibre rather than a schematic map.

---

# Current Problems

The current implementation has several issues:

- Routes are drawn directly between station coordinates.
- Long straight lines cut through buildings.
- Lines ignore tunnels and railway alignments.
- Junctions look artificial.
- Curves disappear.
- Parallel tracks merge together.
- It feels like a graph rather than a railway.

The Real World view should prioritise **accuracy**, whereas the Harry Beck view prioritises **clarity**.

---

# Overall Architecture

The renderer should use real railway geometry rather than station-to-station straight lines.

The recommended pipeline is:

```
OpenStreetMap Railway Data
            │
            ▼
Extract railway graph
            │
            ▼
Match Underground services onto graph
            │
            ▼
Build cached route geometries
            │
            ▼
Render vector polylines
            │
            ▼
Animate live trains
```

---

# Data Source

Use OpenStreetMap railway data.

Relevant features include:

- railway=subway
- railway=rail
- railway=light_rail
- railway=tram (future)
- tunnel=yes
- bridge=yes
- layer
- electrified
- service

Do **not** infer the geometry from station coordinates.

Always use the underlying railway polylines.

---

# Route Matching

Each Underground line should consist of many small OSM segments.

Example:

Instead of

```
Paddington
        │
        │
        │
Bond Street
```

the renderer should follow the actual railway:

```
Paddington
    ╲
     ╲
      ╲
       ╲
        ╱
      ╱
Bond Street
```

Every bend should come from OSM geometry.

---

# Shared Track Sections

Many lines share infrastructure.

Examples include:

- Circle / District
- Metropolitan / Circle
- Circle / Hammersmith & City
- Bakerloo / Overground
- District / Piccadilly

Do not duplicate geometry.

Instead:

- reuse identical railway segments
- offset rendering slightly for multiple lines
- maintain constant spacing

This should match the behaviour seen in TrainTrack UK.

---

# Curves

Real railway curves should be preserved.

Avoid simplifying routes into straight lines.

The map should naturally follow:

- river crossings
- tunnel curves
- station approaches
- junction geometry

Curves are one of the biggest contributors to realism.

---

# Junctions

Branches should occur exactly where the railway branches.

Examples:

- Baker Street
- Earl's Court
- Acton Town
- Camden Town
- Leytonstone

Do not approximate junction positions.

Follow the actual railway graph.

---

# Station Placement

Stations should sit directly on the railway geometry.

For every station:

1. locate nearest railway segment
2. project station onto polyline
3. insert station marker

Avoid floating stations that are disconnected from the railway.

---

# Polyline Quality

Before rendering:

- merge contiguous OSM segments
- remove duplicate vertices
- simplify tiny deviations
- preserve important curves

Use a simplification tolerance appropriate to zoom level.

High zoom should reveal full railway detail.

Low zoom should simplify automatically.

---

# Zoom Levels

The renderer should adapt to zoom.

Far zoom:

- simplified routes
- fewer vertices
- cleaner appearance

Near zoom:

- full railway geometry
- detailed curves
- accurate junctions
- visible sidings where appropriate

---

# Live Train Positioning

Future-proof the renderer for live trains.

A train should:

- move along railway geometry
- interpolate smoothly
- rotate to match track heading
- never jump between stations

The railway polyline should act as the animation path.

---

# Station Labels

Labels should use collision detection.

Requirements:

- avoid overlapping tracks
- avoid overlapping other labels
- offset intelligently
- hide lower-priority labels when necessary

---

# Performance

The railway graph should be built once.

Cache:

- route geometries
- railway graph
- station projections
- polyline offsets

Rendering should remain smooth at 60fps.

Avoid rebuilding the graph during pan or zoom.

---

# Future Expansion

The renderer should be generic enough to support:

- London Underground
- Elizabeth Line
- DLR
- London Overground
- National Rail
- Tramlink
- Future TfL services

Each service should simply reference the same underlying railway graph.

---

# Comparison with TrainTrack UK

The implementation should closely follow the architecture already proven in TrainTrack UK.

Specifically:

- identical route-building pipeline
- identical OSM extraction
- identical graph traversal
- identical polyline smoothing
- identical shared-track handling
- identical caching strategy

Avoid reinventing the routing engine if existing TrainTrack UK components can be reused.

---

# Success Criteria

The finished Real World mode should:

✅ Follow actual railway alignments from OpenStreetMap

✅ Preserve curves and junction geometry

✅ Eliminate unrealistic straight lines

✅ Reuse shared railway segments

✅ Correctly offset multiple Underground lines

✅ Position stations precisely on the railway

✅ Scale cleanly across all zoom levels

✅ Support future live train animations

The resulting map should immediately resemble a professional rail navigation app rather than a station-to-station graph. Users should be able to recognise familiar track layouts, curves and junctions from the real London railway network.