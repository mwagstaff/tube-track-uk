# TubeTrack UK – Harry Beck Map Rendering Engine (Version 2)

## Objective

The previous implementation is **still incorrect**.

Although the renderer now uses rounded stroke joins, the **underlying route geometry remains a series of straight polylines joined at sharp vertices**.

This is **not** how the London Underground map is drawn.

The Harry Beck map does **not** consist of straight segments that simply meet at rounded corners.

Instead, every change in direction is formed using a **smooth tangent curve**. The centreline of the route itself curves.

This redesign is now focused solely on replacing every sharp polyline corner with proper curved geometry.

---

# IMPORTANT

This is **not** a styling task.

It is **not** a lineJoin problem.

It is **not** a lineCap problem.

It is **not** a stroke rendering problem.

It is a **path geometry problem**.

---

# The Current Problem

The renderer currently builds paths like this:

```
moveTo(A)
lineTo(B)
lineTo(C)
lineTo(D)
```

and relies on

```
lineJoin = .round
```

to soften the appearance.

That is fundamentally incorrect.

Even with rounded joins, the underlying centreline still changes direction instantly.

That is exactly what is visible in the current screenshots.

---

# What We Actually Want

Instead of:

```
────────┐
        │
```

we want

```
────────╮
        │
```

Instead of:

```
       /
──────┘
```

we want

```
      ╭
──────╯
```

Notice:

**The centreline itself curves.**

There should never be a visible geometric vertex.

---

# Required Geometry

Whenever two schematic segments meet:

Incoming segment

↓

Corner

↓

Outgoing segment

DO NOT render all the way to the corner.

Instead:

1. Calculate tangent point on incoming segment.
2. Calculate tangent point on outgoing segment.
3. Remove the corner.
4. Connect both tangent points using a circular arc or cubic Bézier.
5. Continue the next straight segment.

The theoretical corner is used only for layout calculations.

It should almost never appear in the rendered path.

---

# Every Direction Change Must Be Curved

This applies to:

Horizontal → Vertical

Vertical → Horizontal

Horizontal → 45°

45° → Horizontal

45° → Vertical

Vertical → 45°

45° → 45°

Every transition should contain a visible tangent curve.

---

# Do NOT Use Rounded Stroke Joins

The following are insufficient:

```
CGLineJoin.round
```

```
lineJoin = .round
```

```
StrokeStyle(lineJoin: .round)
```

```
lineCap = .round
```

Those only change how the vertex is painted.

They do NOT remove the vertex itself.

---

# Preferred Implementation

Every rendered path should conceptually become:

```
moveTo()

lineTo(tangentEntry)

addArc()

lineTo(nextTangent)

addArc()

lineTo(...)
```

or

```
lineTo()

addCurve()

lineTo()

addCurve()
```

depending on the rendering engine.

The important thing is:

**The route centreline must contain actual curved segments.**

---

# Corner Radius

Introduce a design constant:

```
preferredCornerRadius
```

This should be visually tuned rather than mathematically minimal.

The goal is to make curves clearly visible at normal map zoom.

Do not create tiny curves that still appear as sharp corners.

---

# Radius Clamping

Some route segments are short.

Therefore:

```
effectiveRadius = min(
    preferredRadius,
    incomingSegmentLimit,
    outgoingSegmentLimit
)
```

Curves must never overlap.

---

# Parallel Routes

When multiple Underground lines share track:

Calculate one master curve.

Offset every coloured route from that master curve.

Do NOT calculate independent curves for each colour.

The coloured routes should remain perfectly parallel through bends.

---

# Stations

Stations should sit cleanly on the route.

The route should continue beneath the station marker.

Do NOT terminate a curve at a station.

Do NOT use stations to hide poor geometry.

If station circles are hidden, the network should still look beautiful.

---

# Interchanges

Interchange circles must overlay the path.

The underlying geometry should already be correct.

The station circle should never be hiding an ugly corner.

---

# Debug Mode

Add a rendering debug option.

Hide:

- all station circles
- all labels
- all UI

Render only:

- coloured route centrelines

This should immediately reveal whether any sharp corners remain.

---

# Acceptance Test

Zoom into:

- Holborn
- King's Cross St. Pancras
- Baker Street
- Leicester Square
- Charing Cross
- Embankment
- Oxford Circus
- Farringdon

Hide all stations.

Hide all labels.

Inspect every bend.

If a route changes direction at a single identifiable point, the implementation is still wrong.

Every transition should flow smoothly from one direction into the next.

---

# What NOT To Change

For this iteration do **not** modify:

- colours
- fonts
- labels
- station circles
- spacing
- zoom levels
- UI
- toolbar
- disruption panel
- animations

Only replace sharp polyline geometry with tangent curves.

---

# Visual Goal

Every route should read as:

```
Straight
↓

Smooth curve

↓

Straight
```

Never:

```
Straight

↓

Sharp corner

↓

Straight
```

The finished renderer should immediately evoke the official London Underground map.

The user should notice sweeping, elegant route geometry rather than a collection of connected straight lines.

---

# Success Criteria

This task is complete only when:

✅ There are no visible sharp vertices anywhere in the network.

✅ Every direction change uses genuine curved geometry.

✅ Parallel lines remain parallel through curves.

✅ Stations sit naturally on flowing routes.

✅ The network resembles a professionally drafted Harry Beck diagram rather than a graph of connected polylines.

**Treat every remaining sharp corner as a rendering bug.**