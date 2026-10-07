"""Join every visible station circle to a stop and its drawn service.

The reference vectors, rather than the logical station anchors, are the source
of truth for physical tap targets. Piers have coloured backing and are excluded.
"""
import math
from collections import defaultdict

from shapely.geometry import LineString, Point
from shapely.ops import unary_union


OPERATOR_CODES = {
    'chiltern-railways': 'CH', 'c2c': 'CC', 'east-midlands-railway': 'EM',
    'gatwick-express': 'GX', 'great-northern': 'GN', 'great-western-railway': 'GW',
    'greater-anglia': 'LE', 'heathrow-express': 'HX',
    'london-northwestern-railway': 'LM', 'south-western-railway': 'SW',
    'southeastern': 'SE', 'southeastern-high-speed': 'SE', 'southern': 'SN',
    'thameslink-extension': 'TL',
}
OPERATOR_NAMES = {
    'CH':'Chiltern Railways', 'CC':'c2c', 'EM':'East Midlands Railway',
    'GX':'Gatwick Express', 'GN':'Great Northern', 'GW':'Great Western Railway',
    'LE':'Greater Anglia', 'HX':'Heathrow Express', 'LM':'London Northwestern Railway',
    'SW':'South Western Railway', 'SE':'Southeastern', 'SN':'Southern', 'TL':'Thameslink',
}

# These two source circles belong to the separate cable-car interaction layer.
CABLE_TERMINAL_CENTRES = [(1927.647, 1103.523), (2065.291, 1016.182)]
# The DART airport terminal is a transfer landmark, without a rail CRS or
# departure station in the app. Luton Airport Parkway's three rail circles are
# matched normally; do not misidentify this distant airport symbol as Parkway.
AIRPORT_TRANSFER_CENTRES = [(1037.888, 58.266)]

# Reviewed against the April 2026 artwork: these labels sit beside another
# station's tick, or across a long interchange bar. Keep the physical target
# tied to the named roundel rather than whichever text rectangle is closest.
REVIEWED_ROUNDELS = {
    (448.662, 1073.175): ('940GZZLUACT', 'district'),
    (697.065, 1078.014): ('940GZZLUHSD', 'district'),
    (733.548, 1078.014): ('940GZZLUBSC', 'district'),
    (1252.311, 1279.885): ('940GZZLUEAC', 'bakerloo'),
    (1509.727, 639.749): ('910GHGHI', 'great-northern'),
    (1564.994, 639.787): ('910GCNNB', 'windrush'),
    (1904.604, 655.544): ('910GSTFD', 'mildmay'),
    (1274.892, 1744.151): ('910GWCROYDN', 'southern'),
    (2217.435, 407.210): ('910GROMFORD', 'greater-anglia'),
    (745.243, 977.604): ('910GSHPDSB', 'mildmay'),
    (1772.090, 800.618): ('940GZZLUMED', 'district'),
    (2161.521, 719.625): ('940GZZLUBKG', 'district'),
    # Shadwell's DLR circle is east of its shared Overground label; Limehouse's
    # label sits above-left of its circle. Nearest text alone shifts both east.
    (1670.184, 988.235): ('940GZZDLSHA', 'dlr'),
    (1732.836, 988.074): ('940GZZDLLIM', 'dlr'),
}


def bounds(shape):
    points = [c[k] for c in shape['commands'] for k in ('to', 'control1', 'control2') if k in c]
    return (min(p['x'] for p in points), min(p['y'] for p in points),
            max(p['x'] for p in points), max(p['y'] for p in points))


def extract_roundels(shapes):
    outlines = []
    for i, shape in enumerate(shapes):
        if shape['commands'] and shape['fill'] and max(shape['fill']) < .2:
            box = bounds(shape)
            if any(c['op'] == 'cubic' for c in shape['commands']) and max(box[2]-box[0], box[3]-box[1]) < 220:
                outlines.append((i, box))
    circles = []
    for i, shape in enumerate(shapes):
        if not shape['fill'] or min(shape['fill']) < .98 or len(shape['commands']) != 5:
            continue
        if sum(c['op'] == 'cubic' for c in shape['commands']) != 4:
            continue
        box = bounds(shape)
        width, height = box[2]-box[0], box[3]-box[1]
        if not (8 < width < 25 and abs(width-height) < .02):
            continue
        backing = [j for j, b in outlines if b[0]-.05 <= box[0] and b[1]-.05 <= box[1]
                   and b[2]+.05 >= box[2] and b[3]+.05 >= box[3]]
        if not backing:
            continue
        centre = ((box[0]+box[2])/2, (box[1]+box[3])/2)
        # A few interchange circles are printed twice in the source PDF.
        if any(math.dist(centre, c['point']) < 1 for c in circles):
            continue
        circles.append(dict(point=centre, radius=width/2+1.5, sourceShapeIndex=i))
    # Some interchanges are one compound white outline: the circles and their
    # connecting bars share a path. Recover each circle from its curved arcs.
    # A cubic approximation of a circular arc has a stable circumcentre when
    # sampled at its endpoints and midpoint, even when a bar trims the arc.
    for i, shape in enumerate(shapes):
        if not shape['fill'] or min(shape['fill']) < .98:
            continue
        start = None
        recovered = []
        for command in shape['commands']:
            if command['op'] == 'cubic' and start:
                end = tuple(command['to'][k] for k in ('x','y'))
                b,c = [tuple(command[k][axis] for axis in ('x','y')) for k in ('control1','control2')]
                mid = tuple((start[j]+3*b[j]+3*c[j]+end[j])/8 for j in (0,1))
                if math.dist(start,end) > 1.4:
                    ax,ay = (mid[j]-start[j] for j in (0,1))
                    bx,by = (end[j]-start[j] for j in (0,1))
                    determinant = 2*(ax*by-ay*bx)
                    if abs(determinant) > .01:
                        aa,bb = ax*ax+ay*ay,bx*bx+by*by
                        centre = (start[0]+(aa*by-bb*ay)/determinant,
                                  start[1]+(ax*bb-bx*aa)/determinant)
                        radius = math.dist(start,centre)
                        if 4 < radius < 12 and any(
                            box[0] <= centre[0]-radius+.3 and box[1] <= centre[1]-radius+.3
                            and box[2] >= centre[0]+radius-.3 and box[3] >= centre[1]+radius-.3
                            for _,box in outlines
                        ):
                            recovered.append((centre,radius))
            if 'to' in command:
                start = tuple(command['to'][k] for k in ('x','y'))
        for centre,radius in recovered:
            if any(math.dist(centre,c['point']) < 1 for c in circles):
                continue
            peers = [(p,r) for p,r in recovered if math.dist(p,centre)<.3]
            if len(peers) < 2:
                continue
            centre = tuple(sum(p[j] for p,_ in peers)/len(peers) for j in (0,1))
            circles.append(dict(point=centre,radius=sum(r for _,r in peers)/len(peers)+1.5,
                                sourceShapeIndex=i))
    return circles


def path_lines(shape):
    points = []
    for command in shape['commands']:
        op = command['op']
        if op == 'move':
            if len(points) > 1:
                yield LineString(points)
            points = [(command['to']['x'], command['to']['y'])]
        elif op == 'line':
            points.append((command['to']['x'], command['to']['y']))
        elif op == 'cubic' and points:
            a = points[-1]
            b, c, d = [tuple(command[k][axis] for axis in ('x', 'y')) for k in ('control1', 'control2', 'to')]
            steps = max(4, math.ceil((math.dist(a,b)+math.dist(b,c)+math.dist(c,d))/.5))
            for i in range(1, steps+1):
                t = i/steps
                u = 1-t
                points.append(tuple(u*u*u*a[j]+3*u*u*t*b[j]+3*u*t*t*c[j]+t*t*t*d[j] for j in (0,1)))
        elif op == 'close' and points:
            points.append(points[0])
    if len(points) > 1:
        yield LineString(points)


def box_distance(point, box):
    x, y = point
    return math.hypot(max(box[0]-x, 0, x-box[2]), max(box[1]-y, 0, y-box[3]))


def connected_circles(circles, shapes):
    """Solid white interchange bars connect circles; walking dots do not."""
    parent = list(range(len(circles)))
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    by_shape = defaultdict(list)
    for i,circle in enumerate(circles):
        by_shape[circle['sourceShapeIndex']].append(i)
    for indices in by_shape.values():
        for i in indices[1:]:
            parent[root(i)] = root(indices[0])
    for shape in shapes:
        if not shape['fill'] or min(shape['fill']) < .98 or any(c['op']=='cubic' for c in shape['commands']):
            continue
        points = [tuple(c['to'][k] for k in ('x','y')) for c in shape['commands'] if c['op'] in ('move','line')]
        if len(points)>1 and math.dist(points[0],points[-1]) < .01:
            points.pop()
        if len(points) != 4:
            continue
        sides = [math.dist(points[i],points[(i+1)%4]) for i in range(4)]
        short, long = min(sides), max(sides)
        if not (1.5 < short < 6.5 and short*1.5 < long < 180):
            continue
        j = sides.index(short)
        ends = [tuple((points[k][t]+points[(k+1)%4][t])/2 for t in (0,1)) for k in (j,(j+2)%4)]
        nearest = [min(range(len(circles)),key=lambda i:math.dist(circles[i]['point'],p)) for p in ends]
        if all(math.dist(circles[i]['point'],p)<circles[i]['radius']+2 for i,p in zip(nearest,ends)):
            parent[root(nearest[0])] = root(nearest[1])
    groups = defaultdict(list)
    for i,circle in enumerate(circles):
        groups[root(i)].append(circle['point'])
    return [groups[root(i)] for i in range(len(circles))]


def build_roundel_targets(document, stations, label_boxes, route_colors, operator_stations):
    shapes = document['referenceArtwork']['shapes']
    pieces = defaultdict(list)
    for shape in shapes:
        if not shape['stroke'] or shape['width'] < 1.8:
            continue
        for service, color in route_colors.items():
            if max(abs(a-b) for a,b in zip(shape['stroke'],color)) < .0001:
                # Northern and Gatwick Express use the same black ink; the
                # Underground casing is 4.98 artwork units, rail is 5.148.
                if service == 'northern' and abs(shape['width']-4.98) > .01:
                    continue
                if service == 'gatwick-express' and abs(shape['width']-4.98) < .01:
                    continue
                pieces[service].extend(path_lines(shape))
    tracks = {service: unary_union(lines) for service, lines in pieces.items()}
    targets, audit = [], []
    circles = extract_roundels(shapes)
    groups = connected_circles(circles, shapes)
    for circle, group in zip(circles, groups):
        point = circle['point']
        if any(math.dist(point, terminal) < .02 for terminal in CABLE_TERMINAL_CENTRES + AIRPORT_TRANSFER_CENTRES):
            continue
        candidates = []
        for service, track in tracks.items():
            track_distance = track.distance(Point(point))
            if track_distance > circle['radius']+8:
                continue
            eligible = [s for s in stations if s['id'] in label_boxes and (
                (service not in OPERATOR_CODES and service in s['lineIDs'])
                or (service in OPERATOR_CODES and s['id'] in operator_stations.get(service, set())
                    and not (service == 'thameslink-extension' and 'thameslink' in s['lineIDs']))
            )]
            if not eligible:
                continue
            def station_score(station):
                boxes = label_boxes[station['id']]
                local = min(box_distance(point,b) for b in boxes)
                hub = min(box_distance(p,b) for p in group for b in boxes)
                label_score = local*.25+hub*.75
                return label_score
            ranked = sorted((station_score(s), not s['id'].startswith('910G'), s['id']) for s in eligible)
            label_distance, _, station_id = ranked[0]
            # Geometry distinguishes adjacent service-specific circles; labels
            # identify the station along that service, including clipped rail.
            score = track_distance + label_distance*.08 + (.2 if service in OPERATOR_CODES else 0)
            # A shared rail/Overground symbol should open the TfL board. This
            # preference only applies to tracks inside the circle; it cannot
            # steal an adjacent operator-specific circle at an interchange.
            if service not in OPERATOR_CODES and track_distance < 4.5:
                score -= 1
            candidates.append((score, service, station_id, track_distance, label_distance))
        if not candidates:
            raise ValueError(f'No service or station for visible roundel at {point}')
        candidates.sort()
        score, service, station_id, track_distance, label_distance = candidates[0]
        reviewed = next((value for centre,value in REVIEWED_ROUNDELS.items()
                         if math.dist(point,centre) < .02), None)
        if reviewed:
            station_id, service = reviewed
            if station_id not in label_boxes or service not in tracks:
                raise ValueError(f'Stale reviewed roundel {reviewed}')
        target = dict(stationID=station_id, centre=dict(x=round(point[0],3),y=round(point[1],3)),
                      radius=round(circle['radius'],3), sourceShapeIndex=circle['sourceShapeIndex'])
        if service in OPERATOR_CODES:
            target['operatorID'] = 'national-rail:'+OPERATOR_CODES[service]
            target['operatorName'] = OPERATOR_NAMES[OPERATOR_CODES[service]]
        else:
            target['lineID'] = service
        targets.append(target)
        audit.append(dict(target=target, score=round(score,3), trackDistance=round(track_distance,3),
                          labelDistance=round(label_distance,3), alternatives=candidates[1:4]))
    return targets, audit
