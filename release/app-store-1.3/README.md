# TubeTrack UK 1.3 — Thameslink (draft)

Not yet archived or uploaded. The marketing version is already 1.3.

## What this release adds

Thameslink, drawn and served like the Elizabeth line and London Overground:

- The Beck map draws Thameslink as TfL does — a pink line with a dashed white
  inset, interchanges at every shared station and "Towards …" arrows where it
  leaves the map. The real-world map follows the actual track (OpenStreetMap,
  via TrainTrack UK's routed railway graph).
- 62 new stations (the ones the TfL map draws), searchable and joined to their
  interchanges (Farringdon, King's Cross St. Pancras, London Bridge…).
- Departure boards from TfL's National Rail feed, Northbound/Southbound, with
  delays ("Delayed · timetabled 22:29") and cancellations and their reasons.
- Line status and planned works, the line status widget, the Watch and Siri
  line picker.
- Live Activity tracking of a Thameslink board, updated by push.
- Estimated live Thameslink trains on both maps ("Show live trains and
  boats"), placed from station departure boards because TfL publishes no
  Thameslink train positions.
- Journeys that use Thameslink. Other National Rail operators are still never
  offered.
- The status panel and station cards show other National Rail operators'
  service (Southern, Southeastern, Great Northern…) at shared stations.

Suggested What's New text:

> Thameslink is here. See it on both maps, check departures with delays and
> cancellations, track a train on your Lock Screen and plan journeys that use
> it. Stations shared with Southern, Southeastern and other National Rail
> operators now show their service status too.

## Before release

1. **Deploy the API first.** Released 1.2 builds decode line IDs strictly, so
   the server only returns Thameslink to clients that send
   `include=thameslink`. 1.3 sends it, and also sends it to `/api/v1/journeys`,
   which only the new API accepts. Confirm on production:
   - `/api/v1/status` has 20 lines; `/api/v1/status?include=thameslink` has 21.
   - `/api/v1/thameslink/departures?stopIds=910GFRNDNLT,910GSTPXBOX` returns
     rows with `direction` and `status`.
   - `/api/v1/national-rail/status` returns the other operators.
   - `/api/v1/journeys?…&include=thameslink` from West Hampstead Thameslink to
     Blackfriars returns a Thameslink leg.
2. The production TfL key must have headroom: each Thameslink board viewed or
   tracked costs one `ArrivalDepartures` request per stop per 30 seconds
   (shared by everyone watching that stop; push is capped at 40 stops a pass).
   While anyone has live trains shown, estimating Thameslink trains reads all
   65 mapped boards, at most every 45 seconds (about 90 requests a minute).
3. With live trains on, compare Thameslink markers against a departure board
   or a real-time train tracker at a few stations, including the core and the
   Sutton loop.
4. On a weekday, check London Bridge and City Thameslink boards. Both returned
   no departures on the Sunday night they were first probed (City Thameslink is
   closed on Sundays).
5. On a device: start a Thameslink Live Activity, lock the phone, and confirm
   pushed updates, including a cancellation if one occurs.
6. Take new screenshots showing Thameslink on the map and a departure board.
7. Attribution: the real-world map's Thameslink geometry is OpenStreetMap
   (ODbL); the graph already carries "© OpenStreetMap contributors".
