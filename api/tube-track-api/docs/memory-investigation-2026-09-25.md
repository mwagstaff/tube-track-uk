# API memory investigation — 25 September 2026

## Evidence

- Screenshots show repeated V8 heap exhaustion after roughly 19–22 minutes,
  with about 189–192 MiB still live after garbage collection. Several failures
  occur during JSON parsing, which identifies the allocation that failed, not
  necessarily the owner of retained data.
- Read-only checks of `sky` found Node v20.20.2,
  `NODE_OPTIONS=--max-old-space-size=192`, and eight service restarts.
  The actual user service is `com.tube-track-api.api.service`.
- SHA-256 checks confirmed the deployed `lib/live-poller.js` and
  `lib/tfl-client.js` exactly matched the local versions before this fix.
- Sampled upstream responses were ordinary sizes: approximately 2.4 MB for
  Tube, 1.6 MB for Overground and 0.9 MB for Elizabeth line. The sampled live
  snapshot contained 8,612 predictions. These are observations from one poll,
  not maximum payload guarantees.

## Reproduced cause

Each refresh used `AbortSignal.any([shutdownSignal, attemptSignal])` and added
an abort listener to reject its deadline promise. On success the timer was
cleared, but the abort listener was never removed. The shutdown signal lives
for the entire service lifetime, and completed refresh generations remained
reachable on Node v20.20.2.

The synthetic regression exercises the actual client, JSON parser,
normalisation, poller and cache, without network access or credentials. It
holds one shutdown signal across 100 polls, forces GC between polls and uses
weak references to check whether previous generations were collected.

With 2,000 predictions per poll and the same 192 MiB heap limit:

| Measurement | Before | After |
| --- | ---: | ---: |
| Heap after 10 polls | 16.1 MiB | 7.0 MiB |
| Heap after 100 polls | 106.5 MiB | 7.2 MiB |
| Generations still reachable after GC | 100 | 1 |

The regression fails against a saved copy of the original polling module and
passes against the fix. A larger 5,000-prediction probe exhausted the original
heap around poll 60; the fixed version stayed around 10 MiB over 100 polls.
The original probe stayed flat on local Node v26.9.0, so testing only with the
newer developer runtime would have missed the production failure.

## Fix and scope

The poller now forwards shutdown cancellation to each attempt through an
explicit listener and removes both the shutdown and deadline listeners in
`finally`, on success, failure, timeout or cancellation. Deadlines still settle
requests whose underlying fetch ignores abort. No heap increase is required
for this fix.

Tests check cleanup, timeout recovery, shutdown and old-generation collection.
Two existing mocked-fetch timeout tests also now keep the event loop alive
until their deliberately unreferenced deadlines fire, matching the real
server's listening socket and avoiding premature test cancellation on Node 20.

Other reviewed risks include unbounded response buffering and a shared resource
cache bounded by entry count rather than bytes. They can amplify memory use
under large responses or heavy traffic, but neither is needed to reproduce this
leak. They are not claimed as confirmed causes and are unchanged by this fix.

## Rollout verification

The investigation used read-only production access. The fix is local until
deployed. After deployment, follow the service through several former crash
windows (at least one hour):

- Confirm the service restart count does not increase.
- Check `tube_track_nodejs_heap_size_used_bytes` and
  `tube_track_process_resident_memory_bytes` plateau across collection cycles.
  Production memory will exceed the synthetic probe and need not match its
  exact numbers.
- Confirm cache generations continue advancing, `tube_track_live_cache_stale`
  stays zero and `/healthcheck` remains healthy.

The local reproduction is strong evidence for this cause, but it does not
replace observing the deployed fix under real traffic.
