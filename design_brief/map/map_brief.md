# TubeTrack UK – Harry Beck Style Map Rendering Redesign

## Objective

Redesign the TubeTrack UK map renderer so that it closely follows the visual design principles of the iconic Harry Beck London Underground map.

This is **not** simply a UI refresh.

It is a complete redesign of the route layout algorithm and rendering engine to produce an elegant, readable schematic map rather than a geographically accurate one.

The current implementation is technically correct but visually feels "computer generated", with excessive bends, sharp corners and poor visual balance.

The attached TfL Tube Map should be used as the primary design reference for style, spacing and geometry (do **not** copy or trace the artwork directly).

---

# Core Design Principles

The renderer should optimise for:

- readability
- simplicity
- elegance
- consistency
- visual balance
- recognisability

Geographic accuracy is secondary.

Every rendering decision should ask:

> "Would Harry Beck have drawn it this way?"

---

# 1. Route Geometry

## Restrict all line angles

All route segments should snap to only:

- Horizontal (0°)
- Vertical (90°)
- Diagonal (45°)
- Diagonal (135°)

No arbitrary angles.

Never draw:

- 17°
- 29°
- 61°
- shallow diagonals

---

## Minimise bends

Current routes contain far too many unnecessary corners.

Before rendering:

- simplify polylines
- merge almost-collinear segments
- eliminate tiny zig-zags
- remove insignificant deviations

The goal is to produce the minimum number of bends needed to preserve the network topology.

Example:

Bad

```
────┐
    │
 ┌──┘
 │
 └────
```

Good

```
────────╮
        │
        │
        ╰────────
```

---

## Long straight sections

Whenever possible, keep routes straight for long distances.

Avoid staircase patterns.

The user should be able to visually follow a line effortlessly.

---

# 2. Rounded Corners

The current renderer uses harsh 90° corners.

Replace every bend with a smooth circular arc.

Requirements:

- identical radius everywhere
- rounded joins
- rounded end caps
- anti-aliased vector rendering

Suggested corner radius:

10–18 pixels (scaled appropriately with zoom level).

No sharp corners should remain.

---

# 3. Parallel Line Rendering

When multiple Underground lines share the same track:

- maintain constant separation
- ensure perfectly parallel paths
- prevent lines drifting closer together or further apart

Spacing should remain visually identical throughout the shared section.

---

# 4. Junction Design

Branches should split smoothly.

Avoid angular forks.

Current:

```
|
|\
| \
```

Target:

```
|
╰──────
```

Branches should peel away using smooth curves while preserving the standard Beck angles.

---

# 5. Station Placement

Stations should not simply be placed at raw coordinates.

Instead:

- optimise spacing
- prevent clusters
- preserve alignment
- improve readability

Allow stations to move slightly from their geographic positions where necessary.

Even spacing is more important than accuracy.

---

# 6. Station Symbols

Standard stations:

- white fill
- dark outline
- perfect circles

Interchanges:

- slightly larger circles
- consistent styling throughout the map

Avoid varying station sizes except where intentionally required.

---

# 7. Label Placement

Implement an intelligent label placement engine.

Requirements:

- avoid collisions
- never overlap route lines
- never overlap station circles
- prefer horizontal text
- use consistent offsets
- maximise whitespace

If necessary, slightly reposition nearby stations to achieve a cleaner layout.

---

# 8. Central London Optimisation

The current central London area feels cramped.

Increase whitespace by:

- spreading stations
- separating parallel routes
- simplifying geometry
- reducing unnecessary bends

The centre of the map should feel open and balanced rather than dense and chaotic.

---

# 9. Visual Hierarchy

The map should clearly prioritise:

1. Underground lines
2. Stations
3. Labels
4. Service overlays
5. Selection highlights

Labels should never dominate the coloured routes.

---

# 10. Rendering Quality

Use high-quality vector rendering throughout.

Requirements:

- anti-aliasing
- rounded joins
- rounded caps
- pixel-perfect alignment
- crisp rendering on Retina displays

Avoid any jagged edges.

---

# 11. Dynamic Layout Optimisation

After the initial graph layout has been generated, perform one or more optimisation passes.

Possible techniques include:

- force-directed layout
- simulated annealing
- spring constraints
- graph relaxation
- custom heuristics

Optimisation goals:

- minimise bends
- maximise whitespace
- reduce label collisions
- reduce route crossings
- preserve network topology
- improve overall visual balance

---

# 12. Smooth Animations

Transitions between map states should feel polished.

Examples:

- Live Status
- Engineering Works
- Real World mode
- Selected line
- Selected station

Use:

- smooth interpolation
- easing curves
- path morphing
- opacity fades

Avoid abrupt redraws.

---

# 13. Performance

Maintain:

- 60fps panning
- 60fps zooming
- smooth animations

Cache:

- route geometry
- station positions
- label layouts
- rendered paths

Only recompute affected sections when data changes.

---

# 14. Desired Look & Feel

The finished renderer should immediately remind users of the official Tube Map.

The map should feel:

- iconic
- elegant
- calm
- balanced
- uncluttered
- timeless

It should **not** feel like a GIS map or an automatically generated transport network.

---

# Success Criteria

Compared to the existing implementation, the redesigned renderer should achieve:

- Approximately 80% fewer unnecessary bends
- Rounded corners throughout
- Consistent parallel line spacing
- Cleaner branch junctions
- Better station spacing
- Smarter label placement
- More whitespace
- Reduced visual clutter
- Instantly recognisable Harry Beck aesthetic

This should be treated as a significant redesign of the underlying map rendering engine rather than a cosmetic visual refresh.