# Departure platform audit — 23 October 2026

The current iOS departure board reads `/api/v1/departure-board`. This bypassed
the older `StationArrivalsService` Canary Wharf coalescer, so both platform
faces occupied separate rows and inflated the departure count.

`lib/departure-platforms.js` now runs after exact duplicate removal and sorting,
before board limits. Both custom boards (including their background tracking)
and the legacy push projection use it. Raw arrival snapshots stay unchanged.

- Canary Wharf DLR (`940GZZDLCAN`): combine only faces 1/2, 3/4 and 5/6 with
  matching source ID, vehicle ID, direction and destination metadata, and
  expected arrivals within two seconds. Retain both numbers as `Platforms 3 & 4`.
- Tube: combine alternative platform records only for the same nonempty,
  nonzero vehicle ID, station, line, direction and destination metadata within
  two seconds. Show `Check platform`, retaining a shared compass direction.
  These are possible tracks, not evidence that both platforms can be used.
- Keep same-platform records, different vehicles, later services and unknown
  vehicle IDs separate. Do not apply the Tube rule to DLR, trams or railway feeds.
- Compact activity labels use `Platforms 3&4` to fit the existing 14-character
  payload limit without dropping the second boarding platform.

## Live review

Read-only snapshots fetched from TfL's `/Line/{ids}/Arrivals` endpoint around
12:13–12:18 BST. Compared station, line, destination, direction and times across
different platform labels, then replayed normalized records through the merger.

| Feed | Predictions | Stops represented | Findings |
| --- | ---: | ---: | --- |
| DLR | 223 | 41 | Five duplicate rows, all at Canary Wharf; 1/2 and 5/6 active in this snapshot. 3/4 covered by regression fixtures. |
| All 11 Tube lines and tram | 3,620 | 308 | Eighteen non-terminating alternative-platform rows removed across six stations. |
| Elizabeth line and all six Overground lines | 4,053 | 155 | Coincident platform records at Shenfield, Heathrow Terminal 4, Chingford and Enfield Town had different vehicle IDs; retained. |

The six Tube stations and duplicate rows removed were Acton Town (6),
Northfields (4), South Ealing (3), Harrow-on-the-Hill (3), High Street Kensington
(1) and Amersham (1). Placeholder `000` vehicle records remain unmerged.
Terminus records also repeat across platforms at several other stations; the
custom board already excludes self-referential arrivals, and the legacy push
projection already coalesces those terminating predictions.

This is a snapshot review, not proof that every station or operating pattern is
covered. No live National Rail provider audit was performed. Railway and river
deduplication paths were reviewed and are unchanged. Never expand the known
dual-boarding pairs merely because two departures have the same minute label.

## Verification and release

Regression coverage includes all Canary Wharf pairs, source mutation and
idempotence, prediction skew, separate trains/stations/destinations, unknown
vehicle IDs, server-backed board counts and limits, and activity platform labels.
Validation passed: all 332 API tests, 32 focused TubeTrackCore tests on the iOS
simulator, and the app's StationArrivalsServiceTests suite.

Deploy the API changes to correct the current boards and server-generated
activity updates. The Swift formatting change requires the next app release
for locally generated activity labels. No monitoring, alert routing, recovery
permissions or notification scheduling changes are involved.
