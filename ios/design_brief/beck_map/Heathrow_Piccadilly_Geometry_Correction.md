# Correct the Heathrow Piccadilly Line Geometry

The current Heathrow authored slice is **not sufficiently faithful to the official TfL Tube map**.

Please compare the current implementation against the supplied TfL reference image and correct the geometry.

## Critical Principle

Do **not** treat this as a graph-layout problem.

Do **not** position the stations and then generate aesthetically pleasing lines between them.

This part of the Beck map must instead be treated as **fixed, authored diagram geometry**.

The objective is:

> If the station labels, accessibility icons, airport symbols and other TfL furniture were removed from the official map, our Piccadilly line geometry should sit almost exactly on top of the remaining official blue line.

Approximation based merely on connectivity is not acceptable.

---

# What's Wrong With The Current Version

## 1. The Heathrow Terminal 4 loop has the wrong shape

The current implementation creates a large, almost rectangular/U-shaped loop:

- vertical left side
- rounded bottom
- vertical right side
- Hatton Cross effectively sitting at the top-right corner

That is **not the TfL geometry**.

On the official map, the T4 loop is asymmetric.

The line:

1. approaches from **Hounslow West → Hatton Cross** on TfL's standard south-west diagonal
2. continues south-west beyond Hatton Cross
3. bends smoothly into the western side of the Heathrow loop
4. runs down towards the Terminal 4 section
5. has a rounded lower section
6. then turns north
7. rejoins the network near **Heathrow Terminals 2 & 3**

The T4 loop must therefore look like the recognisable TfL Heathrow shape rather than a generic rounded rectangle.

---

## 2. Hatton Cross is not the top-right corner of a vertical loop

The official map maintains the strong **45-degree Piccadilly line diagonal** through the Hounslow / Hatton Cross area.

Hatton Cross belongs naturally on that diagonal.

The loop geometry branches away from that authored alignment; it must not make Hatton Cross look like the corner of a rectangular loop.

---

## 3. Preserve the diagonal

The Hounslow West → Hatton Cross → Heathrow section should remain one coherent diagonal before introducing the Heathrow curves.

---

## 4. Heathrow Terminals 2 & 3 is positioned incorrectly

Author the junction geometry first, then place the station marker onto that geometry.

Do not position the station first and then connect the lines.

---

## 5. The Terminal 5 branch is incorrect

The Terminal 5 branch should:

- follow the official TfL geometry
- remain visually separate from the T4 loop
- not connect into the middle of the T4 loop
- terminate in the same relative position as the official map

---

## 6. Use manually authored geometry

Do **not** generate this layout algorithmically.

Author explicit:

- line segments
- Bézier control points
- arc radii
- junction coordinates

Treat this as a manually drawn vector illustration.

---

## Separate topology from drawing

The operational graph and the rendered Beck geometry are different concepts.

Use hidden geometry control points wherever required.

---

## Trace the TfL map

Overlay the official TfL map and reconstruct the geometry using normalised coordinates and authored control points.

Path geometry takes priority over labels.

---

## Debug overlay

Create a debug mode that overlays our geometry directly on top of the official TfL map at approximately 40% opacity.

Adjust control points until the two geometries closely align.

---

# Most Important Instruction

**Do not redesign the Heathrow Piccadilly layout. Reconstruct it.**

The objective is a manipulable vector recreation of the official TfL Beck geometry that can later support overlays, engineering works and highlighting.
