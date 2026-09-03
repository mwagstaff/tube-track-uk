# TubeTrack UK -- Harry Beck Geometry Authoring Guide (v4)

## Purpose

This document defines **how the TubeTrack UK Harry Beck geometry is
created, validated and maintained**.

It is intended for Codex (or any future AI/developer) as the
authoritative implementation guide for constructing a pixel-faithful
vector representation of the official TfL Tube map.

------------------------------------------------------------------------

# Philosophy

The Harry Beck map is **artwork**, not data.

Therefore:

-   Do **not** derive geometry from latitude/longitude.
-   Do **not** generate geometry from graph algorithms.
-   Do **not** simplify or optimise paths.
-   Do **not** "improve" the TfL design.

Instead:

> Trace the official TfL schematic once and treat the resulting vector
> geometry as immutable source data.

------------------------------------------------------------------------

# Geometry Pipeline

    Official TfL PDF / PNG
              │
              ▼
     Normalise Canvas
              │
              ▼
     Trace Stations
              │
              ▼
     Trace Shared Corridors
              │
              ▼
     Trace Individual Segments
              │
              ▼
     Build Interchanges
              │
              ▼
     Build Labels
              │
              ▼
     Export JSON
              │
              ▼
     SwiftUI Renderer

------------------------------------------------------------------------

# Step 1 -- Normalise the Canvas

Choose a logical design canvas.

Recommended:

    Width  = 10000 units
    Height = 7000 units

Export all coordinates normalised to 0.0--1.0.

Never store pixel coordinates.

------------------------------------------------------------------------

# Step 2 -- Station Placement

Every station is placed manually from the TfL reference.

Each station stores:

-   id
-   display name
-   x
-   y
-   interchange id
-   visible lines
-   label anchor

Stations are **never moved automatically**.

------------------------------------------------------------------------

# Step 3 -- Shared Corridor Authoring

Before drawing any lines, identify every section where multiple
Underground lines follow identical geometry.

Examples:

-   Circle / District
-   Circle / Hammersmith & City
-   Metropolitan / Hammersmith & City
-   Metropolitan / Circle

Create one master path.

Every line references that path with an offset.

Never duplicate geometry.

------------------------------------------------------------------------

# Step 4 -- Segment Authoring

Every section between adjacent stations becomes its own vector object.

Example:

Paddington → Edgware Road

is completely independent from

Edgware Road → Baker Street.

Benefits:

-   Engineering works
-   Live train animation
-   Route highlighting
-   Closures
-   Performance

------------------------------------------------------------------------

# Step 5 -- Canonical Topologies

The following layouts are mandatory canonical templates.

## Heathrow

The Heathrow branch must exactly match TfL.

No inferred branching.

## Northern

The Edgware and High Barnet branches are explicit.

## Circle

Maintain the continuous loop.

## Metropolitan

All branches are represented individually.

## Bank / Monument

Treat as one logical interchange but separate station geometry.

------------------------------------------------------------------------

# Step 6 -- Curves

Curves are authored explicitly.

Rules:

-   Never smooth automatically.
-   Never regenerate Bézier handles.
-   Store control points permanently.
-   Maintain TfL bend radii.

Corner geometry is part of the artwork.

------------------------------------------------------------------------

# Step 7 -- Labels

Labels are authored manually.

Each label stores:

-   x
-   y
-   alignment
-   rotation
-   priority
-   collision group

Automatic label placement is prohibited.

------------------------------------------------------------------------

# Step 8 -- Interchange Templates

Each major interchange is defined once.

Examples:

-   Paddington
-   Baker Street
-   King's Cross St Pancras
-   Waterloo
-   Oxford Circus
-   Liverpool Street
-   Earl's Court
-   Bank / Monument

Each template specifies:

-   station circles
-   connector bars
-   spacing
-   line order
-   label position

------------------------------------------------------------------------

# JSON Versioning

Every geometry release is versioned.

Example:

    tube-map-v1.json
    tube-map-v2.json

Never overwrite geometry.

Future TfL revisions generate a new version.

------------------------------------------------------------------------

# Geometry Validation

Every build runs validation.

Checks include:

✓ Missing stations

✓ Duplicate station IDs

✓ Broken paths

✓ Corridor consistency

✓ Connected topology

✓ Invalid Bézier data

✓ Label overlap

✓ Parallel line spacing

------------------------------------------------------------------------

# Visual Regression

Developer mode provides:

• Official TfL map

• TubeTrack rendering

• Adjustable opacity

• Difference mode

• Control point display

Acceptance:

Maximum visual deviation:

\< 2 pixels on reference device.

------------------------------------------------------------------------

# Geometry Editor (Future)

Long-term goal:

Build an internal geometry editor.

Capabilities:

-   drag stations
-   edit Bézier handles
-   edit labels
-   edit corridors
-   export JSON
-   visual diff
-   undo history

The editor becomes the source of truth.

Codex should generate compatible JSON only.

------------------------------------------------------------------------

# Renderer Contract

The renderer must never:

-   alter geometry
-   optimise paths
-   reposition stations
-   move labels

It only renders the supplied geometry.

------------------------------------------------------------------------

# Engineering Overlay Contract

Geometry:

    Paddington ───── Baker Street

Engineering state:

    closed

Renderer output:

Grey overlay applied.

The underlying path is unchanged.

------------------------------------------------------------------------

# AI Constraints

Codex must not:

-   redraw lines
-   straighten curves
-   remove control points
-   infer station positions
-   merge segments
-   collapse branches

If uncertain, preserve the existing geometry.

------------------------------------------------------------------------

# Deliverables

Codex implementation should produce:

-   stations.json
-   segments.json
-   corridors.json
-   interchanges.json
-   labels.json
-   styles.json
-   SwiftUI renderer
-   Debug overlay mode
-   Geometry validator
-   Snapshot test suite

------------------------------------------------------------------------

# Definition of Done

The Harry Beck implementation is complete only when:

1.  Every station aligns with the official TfL map.
2.  Every line follows the official geometry.
3.  Every branch matches the official schematic.
4.  Shared corridors remain perfectly parallel.
5.  Engineering works require no geometry modification.
6.  Snapshot tests pass.
7.  Overlay comparison against the TfL reference shows no meaningful
    visual differences.

From this point onwards, the Harry Beck map should be treated as a
maintained vector asset rather than an algorithmically generated
diagram.
