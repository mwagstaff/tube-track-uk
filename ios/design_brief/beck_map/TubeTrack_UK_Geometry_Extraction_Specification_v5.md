# TubeTrack UK -- Geometry Extraction Specification (v5)

## Purpose

This document specifies **how to convert the official TfL Tube map into
a maintainable, structured vector dataset** for TubeTrack UK.

The goal is **not** to reproduce the map by approximation. The goal is
to extract a canonical geometry model that can be rendered faithfully
and extended with engineering works, route highlighting and future
overlays.

------------------------------------------------------------------------

# Guiding Principle

Treat the official TfL Tube map as the **master artwork**.

TubeTrack UK should never redesign or reinterpret it.

The extraction process should be deterministic and repeatable.

------------------------------------------------------------------------

# Source Material

Preferred order:

1.  Official vector PDF (best)
2.  Official SVG (if ever published)
3.  High-resolution PNG (minimum 6000 px wide)

Never trace from screenshots of the app.

------------------------------------------------------------------------

# Extraction Pipeline

``` text
Official TfL Artwork
        │
        ▼
Normalise Canvas
        │
        ▼
Detect Lines
        │
        ▼
Detect Stations
        │
        ▼
Split Into Station-to-Station Segments
        │
        ▼
Identify Shared Corridors
        │
        ▼
Detect Labels
        │
        ▼
Generate JSON Assets
        │
        ▼
Run Validation Suite
        │
        ▼
SwiftUI Renderer
```

------------------------------------------------------------------------

# Stage 1 -- Canvas Normalisation

-   Preserve aspect ratio.
-   Define a canonical design space (e.g. 10,000 × 7,000 units).
-   Store all coordinates normalised to 0.0--1.0.

This ensures device-independent rendering.

------------------------------------------------------------------------

# Stage 2 -- Line Extraction

For each Underground line:

-   Bakerloo
-   Central
-   Circle
-   District
-   Hammersmith & City
-   Jubilee
-   Metropolitan
-   Northern
-   Piccadilly
-   Victoria
-   Waterloo & City

Extract:

-   stroke colour
-   stroke width
-   vector path
-   bends
-   Bézier control points

Never simplify geometry.

------------------------------------------------------------------------

# Stage 3 -- Station Detection

For every station:

Capture:

-   identifier
-   display name
-   centre point
-   interchange membership
-   connected lines
-   label reference

Do not infer missing stations.

------------------------------------------------------------------------

# Stage 4 -- Segment Generation

Split every line at every station.

Result:

    Paddington
       │
    segment
       │
    Edgware Road
       │
    segment
       │
    Baker Street

Every segment receives a globally unique identifier.

Benefits:

-   closures
-   engineering works
-   route animation
-   accessibility overlays

------------------------------------------------------------------------

# Stage 5 -- Shared Corridor Detection

Automatically identify geometrically identical paths.

Examples:

-   Circle + District
-   Circle + Hammersmith & City
-   Metropolitan + Hammersmith & City

Create one master corridor with per-line offsets.

No duplicated vector data.

------------------------------------------------------------------------

# Stage 6 -- Interchange Recognition

Recognise complex stations:

-   Paddington
-   Baker Street
-   Bank / Monument
-   King's Cross St Pancras
-   Earl's Court
-   Liverpool Street
-   Oxford Circus
-   Waterloo

Generate reusable interchange templates.

------------------------------------------------------------------------

# Stage 7 -- Label Extraction

Each label becomes structured data.

``` json
{
  "station":"paddington",
  "x":0.41,
  "y":0.37,
  "alignment":"left",
  "rotation":0,
  "priority":10
}
```

Automatic label placement is prohibited.

------------------------------------------------------------------------

# Geometry Schema

## stations.json

Stores nodes.

## segments.json

Stores independent station-to-station paths.

## corridors.json

Stores shared master paths.

## interchanges.json

Stores reusable interchange layouts.

## labels.json

Stores manual label placement.

## styles.json

Stores colours, widths and offsets.

------------------------------------------------------------------------

# Validation Rules

The extraction pipeline must fail if:

-   station count changes unexpectedly
-   disconnected topology exists
-   duplicate station IDs appear
-   corridor offsets diverge
-   labels overlap protected zones
-   Bézier paths become invalid

------------------------------------------------------------------------

# Visual Regression

Generate snapshots automatically.

Compare against the official TfL artwork.

Metrics:

-   RMS pixel difference
-   station centroid error
-   path deviation
-   corridor spacing
-   label displacement

Suggested tolerance:

-   Station error ≤ 2 px
-   Path deviation ≤ 2 px
-   Label deviation ≤ 3 px

------------------------------------------------------------------------

# Snapshot Tests

Include reference renders for:

-   Light mode
-   Dark mode
-   Engineering works
-   Selected route
-   Heathrow branch
-   Northern split
-   Circle loop

------------------------------------------------------------------------

# Build Outputs

The extraction tool should generate:

    stations.json
    segments.json
    corridors.json
    labels.json
    interchanges.json
    styles.json

    validation-report.json
    snapshot-report.html

------------------------------------------------------------------------

# Future Updates

When TfL publishes a revised map:

1.  Re-run extraction.
2.  Compare against previous geometry.
3.  Produce a change report.
4.  Increment geometry version.
5.  Leave renderer unchanged.

Only the data changes.

------------------------------------------------------------------------

# Definition of Done

The project is complete when:

-   The extracted geometry is visually indistinguishable from the
    official TfL map.
-   Every station-to-station section is independently addressable.
-   Engineering works require only state changes.
-   No runtime layout or routing algorithms exist.
-   Geometry can be regenerated from a new TfL source using the same
    extraction pipeline.

At that point, TubeTrack UK's Harry Beck view becomes a stable,
versioned vector asset rather than generated artwork.
