# TubeTrack UK — Implement Proper Map Label Placement & Decluttering

The station labelling on the schematic Tube map is currently unusable. Please redesign the label-rendering system rather than applying individual station-specific fixes.

Use the attached/current screenshots as examples of the problems: station names overlap each other, labels sit directly over route lines and station markers, minor stations remain visible when heavily zoomed out, and dense areas become unreadable.

## Goal

Implement a proper **zoom-aware, priority-based cartographic label placement algorithm** so the map remains clean and legible at every zoom level.

### 1. Introduce station label priorities

Every station should have a label priority derived from its importance, for example:

1. **Major interchange / terminus**
   - Multiple Underground lines
   - National Rail interchange
   - Major termini
   - Important central London hubs

2. **Interchange**
   - Two or more relevant lines/services

3. **Normal station**

4. **Low-priority/minor station**

Do **not** simply use font size to distinguish these. The key behaviour is whether the label is shown at the current zoom.

### 2. Use zoom-dependent visibility tiers

At low zoom levels, show **only major/interchange labels**.

As the user zooms in, progressively reveal more stations.

For example:

- **Overview zoom:** major hubs / termini only
- **Medium zoom:** major hubs + interchanges
- **Closer zoom:** most stations
- **Detailed zoom:** all station names

Determine sensible thresholds based on the existing map coordinate/zoom system rather than blindly using these exact categories.

The first screenshot should never display dozens of small labels such as *Mitcham, Reeves Corner, Peckham Rye, Nine Elms,* etc. simultaneously at that scale.

### 3. Add real collision detection

Before drawing a station name, calculate its actual rendered bounding box.

A label must not be drawn if its bounds substantially intersect:

- another already-accepted station label
- another important annotation
- a station/interchange symbol
- UI-safe areas where appropriate

Process labels **highest priority first**, so important labels win and less important labels are suppressed.

Do not allow two labels to overlap just because their station coordinates differ.

### 4. Automatically choose the best label position

Do not assume every label should appear in one fixed position relative to its station.

For each station, evaluate candidate positions such as:

- right
- left
- above
- below
- upper-right
- upper-left
- lower-right
- lower-left

Score each candidate and choose the cleanest available position.

Prefer the station's existing/designed orientation where one exists, but automatically fall back to alternatives when that would cause a collision.

### 5. Avoid route lines

A label should strongly prefer not to sit on top of a Tube/rail line.

When scoring candidate positions, penalise or reject placements whose label bounding rectangle intersects route geometry.

Allow a small configurable padding around lines so text does not visually touch them.

This is especially important for the second screenshot, where labels such as *Clapham Junction*, *Clapham Common*, *Balham* etc. are being placed directly across or beside heavy line geometry.

### 6. Leave breathing room

Apply sensible minimum padding between:

- label ↔ label
- label ↔ station marker
- label ↔ route line

Use screen-space points/pixels for these clearances so readability remains consistent regardless of map scale.

### 7. Make placement deterministic and visually stable

Labels must **not jump around continuously while panning or making tiny zoom changes**.

Use stable ordering and preferably some hysteresis/caching so a label that is visible remains visible until there is a meaningful reason to change it.

Avoid flickering at zoom thresholds.

### 8. Keep labels inside useful screen/map bounds

Do not position labels where they are partly clipped offscreen or hidden underneath:

- the iOS status area
- floating controls
- the disruption panel
- bottom navigation

Account for the map's actual visible viewport/insets.

### 9. Preserve proper Tube-map typography

Keep the existing station-name styling unless necessary, but ensure:

- consistent font size within each label class
- sensible multiline wrapping for genuinely long names
- no accidental text truncation
- no labels rendered over themselves
- no duplicate labels for the same physical/interchange station

Do not shrink text to tiny sizes merely to make everything fit. **Hide lower-priority labels instead.**

### 10. Architecture

Please implement this as a reusable labelling/layout component rather than a collection of hard-coded station exceptions.

Something conceptually similar to:

`StationLabelLayoutEngine`

taking:

- visible stations
- station metadata / priority
- projected screen coordinates
- current zoom
- visible route geometry
- viewport bounds

and returning:

- which labels should be displayed
- their chosen screen positions/alignment
- their bounding rectangles

A rough algorithm is:

1. Filter stations by zoom-level eligibility.
2. Calculate label priority.
3. Sort highest-priority first.
4. Generate candidate placements for each label.
5. Score candidates for:
   - label collisions
   - line intersections
   - marker clearance
   - viewport clipping
   - distance from preferred placement
6. Accept the best valid candidate.
7. Suppress the label if no sufficiently clean position exists.
8. Render only accepted labels.

### Acceptance criteria

After the change:

- Zoomed-out London view is clean and shows only the most important station names.
- Major/interchange labels are never hidden in favour of ordinary stations.
- Station names do not overlap one another.
- Labels should almost never sit directly across route lines.
- Dense areas such as central London remain readable.
- More labels progressively appear as the user zooms in.
- At close zoom, virtually/all station names can become visible.
- Label placement remains stable while panning and zooming.
- There should be no station-specific hacks unless absolutely unavoidable.

Please inspect the existing map renderer and implement this cleanly within its current architecture. Refactor the existing station-name rendering as necessary rather than layering additional ad-hoc checks on top of it.