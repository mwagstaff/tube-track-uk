# TfL Map Structural Fidelity Audit

## Anti-pattern verdict

Pass for the audited map layer. The artwork is authored, data-driven, and restrained; the current risk is fidelity drift, not generic decorative UI. This report does not assess unrelated screens.

## Executive summary

- Reference: Transport for London Standard Tube Map (April 2026)
- Artwork: `tube-track-uk.beck.full-underground.v1`
- Findings: 5 total (medium: 5)
- Status: candidate deviations require visual confirmation against the locked reference before geometry changes

### Most important next steps

1. Keep the high-severity audit gate enabled to prevent structural regressions.
2. Visually adjudicate medium route and connector angle candidates against the official artwork.
3. Pin source-profile-correct line colours and add masked visual comparisons.
4. Convert confirmed medium corrections into station- and segment-specific regression fixtures.

## Detailed findings by severity

### Critical (0)

No findings.

### High (0)

No findings.

### Medium (5)

#### `non-canonical-straight-runs` - dlr

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: An unexplained angle may expose slice-seam drift, but the official artwork also contains intentional exceptions.
- Recommendation: Compare each command with the locked artwork; correct only source mismatches and retain traced exceptions.
- Evidence: `{"candidates":[{"angleDegrees":44.6,"commandIndex":1,"deviationDegrees":0.4,"length":132.541,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.dlr.stratford-lewisham.official.v1.1","segmentID":"dlr:940GZZDLBOW:940GZZDLPUD"},{"angleDegrees":44.6,"commandIndex":1,"deviationDegrees":0.4,"length":172.388,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.dlr.stratford-lewisham.official.v1.0","segmentID":"dlr:940GZZDLPUD:940GZZDLSTD"}],"count":2,"lineID":"dlr","maximumDeviationDegrees":0.4}`

#### `non-canonical-straight-runs` - mildmay

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: An unexplained angle may expose slice-seam drift, but the official artwork also contains intentional exceptions.
- Recommendation: Compare each command with the locked artwork; correct only source mismatches and retain traced exceptions.
- Evidence: `{"candidates":[{"angleDegrees":43.693,"commandIndex":3,"deviationDegrees":1.307,"length":32.955,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.mildmay.stratford-clapham.official.v1.3","segmentID":"mildmay:910GDALSKLD:910GHACKNYC"},{"angleDegrees":43.831,"commandIndex":5,"deviationDegrees":1.169,"length":69.377,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.mildmay.stratford-clapham.official.v1.3","segmentID":"mildmay:910GDALSKLD:910GHACKNYC"}],"count":2,"lineID":"mildmay","maximumDeviationDegrees":1.307}`

#### `non-canonical-straight-runs` - northern

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: An unexplained angle may expose slice-seam drift, but the official artwork also contains intentional exceptions.
- Recommendation: Compare each command with the locked artwork; correct only source mismatches and retain traced exceptions.
- Evidence: `{"candidates":[{"angleDegrees":89.721,"commandIndex":3,"deviationDegrees":0.279,"length":12.75,"nearestCanonicalAngle":90.0,"pathID":"beck.v1.path.northern.edgware.north-connector.v1.8","segmentID":"northern:940GZZLUCFM:940GZZLUCTN"},{"angleDegrees":89.727,"commandIndex":6,"deviationDegrees":0.273,"length":12.597,"nearestCanonicalAngle":90.0,"pathID":"beck.v1.path.northern.high-barnet.north-connector.v1.9","segmentID":"northern:940GZZLUCTN:940GZZLUKSH"}],"count":2,"lineID":"northern","maximumDeviationDegrees":0.279}`

#### `non-canonical-straight-runs` - victoria

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: An unexplained angle may expose slice-seam drift, but the official artwork also contains intentional exceptions.
- Recommendation: Compare each command with the locked artwork; correct only source mismatches and retain traced exceptions.
- Evidence: `{"candidates":[{"angleDegrees":44.203,"commandIndex":5,"deviationDegrees":0.797,"length":88.994,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.victoria.north-connector.v1.1","segmentID":"victoria:940GZZLUHAI:940GZZLUKSX"},{"angleDegrees":44.483,"commandIndex":7,"deviationDegrees":0.517,"length":22.032,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.victoria.north-connector.v1.1","segmentID":"victoria:940GZZLUHAI:940GZZLUKSX"}],"count":2,"lineID":"victoria","maximumDeviationDegrees":0.797}`

#### `unverified-line-colour-profile` - TubeLine.swift

- Category: styles
- Description: The audit manifest does not yet contain colour-profile-corrected values extracted from the locked vector source.
- Impact: Even geometrically accurate lines may render with visibly incorrect TfL colours.
- Recommendation: Extract source colours through the PDF's intended ICC profile, then pin perceptual tolerances per line.
- Evidence: `{"status":"pending source-profile extraction"}`

### Low (0)

No findings.

### Info (0)

No findings.

## Patterns and systemic issues

- Geometry correctness is strongly covered for selected showcase interchanges, but not yet for every primitive.
- Marker dimensions are consistent, while their fidelity to the official source still needs source-layer measurement.
- Route and connector angle exceptions are implicit; they need explicit, reviewable provenance.
- Colour and local crossing order are not yet pinned by the audit manifest.

## Positive findings

- All 619 authored segments retain stable semantic IDs.
- The document includes 509 marker records and 620 immutable paths.
- The official PDF and raster are checksum-pinned, protecting the comparison from silent source changes.
- Structural findings identify exact station, segment, path, and primitive locations.

## Recommendations by priority

1. Immediate: resolve critical source/topology failures, if any.
2. Short-term: visually adjudicate medium connector, roundel, tick, and route candidates.
3. Medium-term: implement confirmed geometry corrections in a new versioned artwork asset.
4. Long-term: add colour-managed pixel masks and local crossing-order regression tests.

## Reproduction

Run `python3 Tools/BeckMapBuilder/audit_map_fidelity.py --help` from the `ios` directory.
