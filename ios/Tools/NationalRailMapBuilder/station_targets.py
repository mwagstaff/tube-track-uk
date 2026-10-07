"""Bind visible ticks to the independently reviewed April 2026 station list.

reviewed-station-targets.csv records the printed station name and service for
every circle and tick. New map editions must be reviewed before publication;
nearest-label guesses must never silently change the station a passenger taps.
"""
import csv
import math
from pathlib import Path

from roundel_targets import OPERATOR_NAMES


def reviewed_targets():
    with Path(__file__).with_name('reviewed-station-targets.csv').open() as file:
        return list(csv.DictReader(file))


def extract_ticks(shapes, circles, colors):
    result = []
    for index, shape in enumerate(shapes):
        if not shape['fill'] or len(shape['commands']) != 5:
            continue
        if any(command['op'] == 'cubic' for command in shape['commands']):
            continue
        points = [tuple(c['to'][k] for k in ('x', 'y'))
                  for c in shape['commands'] if 'to' in c][:4]
        if len(points) != 4:
            continue
        lengths = [math.dist(points[j], points[(j+1) % 4]) for j in range(4)]
        width, length = min(lengths), max(lengths)
        # Include the shorter ticks on clipped limited-service branches.
        if not (3.1 < width < 3.8 and 3.5 < length < 15):
            continue
        services = [service for service, color in colors.items()
                    if max(abs(a-b) for a, b in zip(shape['fill'], color)) < .0001]
        if not services:
            continue
        centre = tuple(sum(p[k] for p in points)/4 for k in (0, 1))
        if any(math.dist(centre, tuple(c['centre'].values())) < c['radius']+1 for c in circles):
            continue
        if any(math.dist(centre, t['point']) < .1 and set(services) == set(t['services']) for t in result):
            continue
        edge = min(range(4), key=lambda j: lengths[j])
        start = tuple((points[edge][k]+points[(edge+1) % 4][k])/2 for k in (0, 1))
        end = tuple((points[(edge+2) % 4][k]+points[(edge+3) % 4][k])/2 for k in (0, 1))
        result.append(dict(point=centre, start=start, end=end, width=width,
                           sourceShapeIndex=index, services=services))
    return result


def bind_reviewed_targets(document, stations, colors):
    artwork = document['referenceArtwork']
    by_id = {s['id']: s for s in stations}
    expected = reviewed_targets()
    circles = artwork['stationRoundels']
    ticks = extract_ticks(artwork['shapes'], circles, colors)
    from roundel_targets import OPERATOR_CODES
    matched = set()
    targets = []
    for kind, items in [('circle', circles), ('tick', ticks)]:
        for item in items:
            centre = tuple(item['centre'].values()) if kind == 'circle' else item['point']
            hits = [(i, row) for i, row in enumerate(expected) if row['kind'] == kind
                    and math.dist(centre, (float(row['x']), float(row['y']))) < .02]
            if len(hits) != 1:
                raise ValueError(f'Unreviewed or ambiguous {kind} at {centre}')
            index, row = hits[0]
            matched.add(index)
            station = by_id[row['stationID']]
            if station['name'] != row['name']:
                raise ValueError(f'Station identity changed: {row}')
            if kind == 'circle':
                actual = (item['stationID'], item.get('lineID', ''), item.get('operatorID', ''))
                if actual != (row['stationID'], row['lineID'], row['operatorID']):
                    raise ValueError(f'Roundel assignment changed: {row}, generated {actual}')
                continue
            services = item['services']
            if row['lineID']:
                if row['lineID'] not in services:
                    raise ValueError(f'Tick colour changed: {row}')
            elif row['operatorID'] not in ['national-rail:'+OPERATOR_CODES[s] for s in services if s in OPERATOR_CODES]:
                raise ValueError(f'Rail tick colour changed: {row}')
            target = dict(stationID=row['stationID'], centre=dict(zip(('x','y'), map(lambda v: round(v,3), centre))),
                          start=dict(zip(('x','y'), map(lambda v: round(v,3), item['start']))),
                          end=dict(zip(('x','y'), map(lambda v: round(v,3), item['end']))),
                          width=round(item['width'],3), sourceShapeIndex=item['sourceShapeIndex'])
            if row['lineID']:
                target['lineID'] = row['lineID']
            else:
                target['operatorID'] = row['operatorID']
                target['operatorName'] = OPERATOR_NAMES[row['operatorID'].split(':')[1]]
            targets.append(target)
    if len(matched) != len(expected):
        raise ValueError(f'Missing reviewed source targets: {[r for i,r in enumerate(expected) if i not in matched]}')
    artwork['stationTicks'] = targets
    # Keep focus and accessibility anchors on an actual symbol for the stop.
    for marker in document['stationMarkers']:
        own = [t for t in circles+targets if t['stationID'] == marker['stationID']]
        if not own:
            hub = by_id[marker['stationID']].get('hubID') or marker['stationID']
            own = [t for t in circles+targets if (by_id[t['stationID']].get('hubID') or t['stationID']) == hub]
        if not own:
            raise ValueError(f'No physical marker for {marker["stationID"]}')
        best = min(own, key=lambda t: math.dist(tuple(t['centre'].values()), tuple(marker['anchor'].values())))
        marker['anchor'] = best['centre'].copy()
        for primitive in marker['primitives']:
            if primitive['kind'] == 'circle':
                previous = tuple(primitive['circle']['centre'].values())
                target = min(own, key=lambda t: math.dist(tuple(t['centre'].values()), previous))
                primitive['circle']['centre'] = target['centre'].copy()
    return targets
