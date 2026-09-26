# River Bus implementation and API findings

## Scope

River Bus layer shown by default on both app maps, with remembered visibility in Profile → Preferences; 24 bundled piers;
predicted pier arrivals presented as departure-board information; independent
service status; shared station/pier favourites; conservative estimated boats.
No GPS/AIS claims. Journey planning, widgets and Live Activities remain rail-only.

## Live probes: 24 September 2026, approximately 23:46–23:49 UTC

Recorded responses are in `test/fixtures/river`. These are source observations,
not mocked live data. The probe ran after the principal service period.

| Endpoint | Observation |
| --- | --- |
| `/Line/Mode/river-bus` | RB1, RB4, RB6 and Woolwich Ferry. RB services are discovered by identifier family, not a fixed route array. Woolwich Ferry is excluded from this Thames Clippers scope. |
| `/StopPoint/Mode/river-bus` | 93 records including 26 FerryPorts. 24 belong to RB services. Piers contain berth, entrance and access-area children; some also contain bus stops. |
| `/Mode/river-bus/Arrivals?count=-1` | 23 predictions, all expired at capture. A fresh `timestamp` did not mean `expectedArrival` was current. `timeToStation` was absent. |
| Parent and child `/StopPoint/{id}/Arrivals` | Empty responses at Westminster, Embankment, London Bridge City, Canary Wharf, Battersea Power Station, Greenwich and North Greenwich. Full queried ID list retained in `pier-arrivals.json`. |
| RB1/RB4/RB6 `/Route/Sequence/{direction}` | 11 ordered route variants across both directions, including an RB4 river crossing. Branch sequences are not interchangeable with complete route variants. |
| `/Line/Mode/river-bus/Status` | Supported; all four services returned Good Service at capture. Unknown/no entries must not imply Good Service. |
| `/Line/rb1/Timetable/930GWMR` | Direction disambiguation, not a ready departure board. No scheduled fallback is invented. |

Example canonical pier IDs: `930GWMR` Westminster; `930GEMB` Embankment;
`930GLBR` London Bridge City; `930GCAW` Canary Wharf; `930GBSP` Battersea
Power Station; `930GGNW` Greenwich. IDs are preserved exactly.

Populated prediction fields included `vehicleId`, `tripId`, `naptanId`,
`lineId`, `lineName`, `platformName`, `direction`, `destinationNaptanId`,
`destinationName`, `timestamp`, `expectedArrival`, `timeToLive`, `modeName`.
`currentLocation` and `towards` were empty. In this capture `vehicleId`
matched `tripId`: it is treated as an opaque prediction identity, never a
verified physical vessel identity or AIS MMSI.

### Limits of the probe

Empty parent/child responses do **not** establish which level supplies complete
departures during service hours. The implementation aggregates a known parent
and its ferry berths, excludes bus stops/entrances/access areas, and deduplicates.
The active-service probe below improves this evidence, but neither probe establishes
complete fleet coverage or verifies physical vessel identity continuity.

## API contract

New opt-in routes leave legacy rail responses and the rail poller unchanged:

- `GET /api/v1/river/network`: dynamic lines, logical piers and ordered routes;
  24-hour upstream cache; bundled iOS metadata provides offline first launch.
- `GET /api/v1/river/arrivals/{pierId}`: parent/berth aggregation, 30-second
  shared cache, normalized dates, expired/malformed rows removed.
- `GET /api/v1/river/live`: mode-wide predictions, shared 30-second cache.
- `GET /api/v1/river/boats`: shared estimated positions, using the same cached
  predictions as `/live`; no additional upstream request per phone or pier.
- `GET /api/v1/river/status`: independent status, shared 60-second cache.

All retain the standard `{ data, meta: { updatedAt, cached, stale } }` envelope.
Live normalization is repeated when serving cached data, so expiry still
advances. The iOS client repeats expiry checks as countdowns tick. Requests
coalesce through ResourceCache and use the existing TfL concurrency limits.
Phones poll only on an active, online map with River Bus enabled. There is no
timer per pier and no new always-on server polling loop.

Deploy the companion API before releasing the app. No TfL key belongs in iOS.
The app falls back to its legacy transition-based estimator when `/boats` returns
404, and probes for the new endpoint again after five minutes. Immediate shared
estimates require the updated API; bundled piers and favourites remain usable offline.

## Maps and estimates

`RiverSchematic.json` contains explicit pier anchors on the unchanged authored
Thames, bank offsets and overview priority. New unanchored piers are searchable
and open on the geographic map. They are never geographically interpolated into
the schematic railway artwork. Both maps distinguish pier circles from
boat-shaped estimated-position markers. Service selection highlights river paths.
Labels are progressively revealed; schematic label placement avoids rail labels.

TfL's route lineStrings are straight pier-to-pier chords, unsuitable for boat
positions around river bends. `RiverGeometry.json` contains a connected OSM
Thames centreline, stitched by node identity and trimmed between Putney and
Barking Riverside. Its metadata records source, licence and OSM data timestamp.
The existing OpenStreetMap attribution remains visible in the geographic view.

The API learns travel duration from the difference between one journey's predicted
arrival times at consecutive calling piers. It keeps up to nine distinct journey
samples per service, direction and pier pair, and uses their median. Repeated
cached reads do not reweight a sample. Models expire after 24 hours and reset if
the route catalogue changes.

On first load, a boat can appear when its next pier has one unambiguous preceding
pier on compatible routes, a learned duration exists for that leg, and subtracting
that duration from its ETA puts departure in the past. Learning runs across all
journeys before positioning, so another journey in the same response can provide
the duration immediately. If no same-direction sample exists, the estimator can
use the same service’s reverse leg where an ordered return route confirms the
adjacent pier pair (`basis: reverseTravelTime`). Same-direction samples always
take precedence. This is an approximation: upstream and downstream durations
can differ. It does not borrow timings from other services or other pier pairs.
Future origin departures are excluded. For example,
an eight-minute learned leg with an arrival due in two minutes places the estimate
75% along the river path. Motion assumes uniform progress within that leg; dwell,
tides, speed changes and unreported express patterns can affect accuracy.

Subsequent observed next-pier transitions refine estimates using the previous ETA
as segment start. A skipped-stop segment requires the previous snapshot to identify
the same journey's next calling pier, in forward route order. Cached responses can
witness a transition as their earliest prediction expires; millisecond timestamp
skew between piers does not block this. Missing identity, conflicting ETAs,
ambiguous predecessors, incompatible routes and implausible durations suppress
positions. Changed journey identities replace old markers; older responses cannot
rewind them.

History and timing samples are shared by all clients of one API process, bounded
to 512 entries per collection. They are not persisted across server restarts or
shared across replicas. A fresh snapshot can seed a new process immediately;
there is no always-on poller or per-phone warm-up requirement for inferred legs.

A brief empty response or request failure retains valid estimates until the next
pier ETA or 90 seconds after the original source observation, whichever is sooner.
Holding a marker never refreshes its age. TfL's shorter prediction-cache TTL still
controls acceptance of new observations, but does not prematurely expire a derived
position. The API marks empty/stale-feed responses stale; the boat card uses the
shared update footer to show a delayed/offline warning. The app independently
checks each boat's source age and expiry. These are estimates from pier predictions,
not confirmed departures, docking observations or GPS positions.

### Active-service replay: 25 September 2026, 11:16–11:19 UTC

A network response contained 101 predictions across 19 journey identities. Spot
checks of Westminster, Canary Wharf, Greenwich and Putney departure boards found
no additional identities beyond the mode-wide feed. Separate requests to every
pier therefore offered no demonstrated coverage gain. Not every journey was
already sailing: future departures and ambiguous routes remain excluded.

The feed briefly returned zero predictions between populated responses. Before
the reverse-leg fallback, replaying the captured sequence produced:

| Capture (UTC) | Predictions | Estimated boats |
| --- | ---: | ---: |
| 11:16:14 | 101 | 4 |
| 11:17:33 | 104 | 6 |
| 11:18:06 | 0 | 6 retained within original expiry |
| 11:18:36 | 105 | 6 |
| 11:19:07 | 103 | 7 |
| 11:19:38 | 104 | 7 |

Before the reverse-leg fallback, starting independently from the recorded
104-prediction snapshot produced five boats immediately. With that fallback it
produces seven: the original five plus two based on return-leg timings. That snapshot is retained in `test/fixtures/river/live-2026-09-25.json`
with regression assertions for first-load estimates, the empty response and expiry.
This verifies behavior against a captured feed, not current fleet completeness.

## Verification

Server tests cover recorded discovery, new services, berth deduplication,
expired/invalid data, cache coalescing and isolated failures. iOS tests cover
identity/route gates, expiry, cross-river geometry, pier-anchor integrity,
geographic paths, selection and persisted favourites. Validation: the complete server suite passed (174 tests); the simulator build
and 38 targeted iOS tests passed. Simulator checks exercised Westminster,
Canary Wharf and Royal Wharf, light/dark appearances, accessibility-large text,
empty/offline boards, synthetic populated boards, geographic placement and
switching between maps with a pier selected, service filters, persisted
favourites/search and a synthetic RB4 boat transition. Synthetic data is only
used by a local QA server, never bundled as live predictions. Real active-service
fleet completeness and physical boat continuity remain a release-validation task.

Use the Debug-only launch arguments `-DebugRiverBus` and
`-DebugRiverPier 930GCAW` to open a representative area. Combine with
`-DebugOffline` for offline checking, or `-DebugMapMode realWorld` for Apple Maps.

Shared-estimator tests additionally cover first-load timing inference, shared HTTP
cache behavior, stale/error retention, fixed source expiry, future journeys, branch
ambiguity, identity changes, older snapshots and source timestamp skew. iOS tests
cover the `/boats` contract, stale/error/fresh-empty state transitions and staged
rollout fallback to `/live`.

Final validation on 25 September 2026: all 197 API tests and 19 targeted iOS
River Bus/update-footer tests passed, including a successful simulator build.
Simulator QA against a local server using the real estimator confirmed a boat
on first load, selection and the update footer on the geographic map, preserved
selection when switching to the schematic map, and the delayed-update icon and
warning while retaining the boat through a feed gap. QA predictions were synthetic
and are not included in app resources.

### Royal Wharf missing approach correction

The Royal Wharf report showed an outbound RB1 due in two minutes without a
nearby marker. A live follow-up at 11:44 UTC confirmed that the updated `/boats`
endpoint was deployed and then showed that journey from Royal Wharf to Woolwich.
The exact screenshot-time response was not retained, so it cannot prove the
historical cause. Code inspection and a regression reproduction identified a
cold-start gap: no same-direction timing sample meant no approaching marker, even
when a future inbound trip provided the same pier pair’s return timing.

`royal-wharf-return-2026-09-25.json` records that inbound trip. A synthetic outbound
Royal Wharf prediction due in two minutes, combined with those recorded rows, now
produces a North Greenwich → Royal Wharf estimate halfway through the learned
four-minute return duration. Tests preserve ambiguity, future-departure, service
identity and source-expiry checks, and prefer actual-direction samples. This is an
API-only change; the existing app already accepts the new basis string and draws
the resulting segment on both maps. Deploy/restart the API to enable it.
