"""Reviewed river/cable coordinates in the combined PDF's page space.

The original Tube map has different geometry. These anchors retain existing
pier/boat/terminal interactions when switching to the combined artwork.
"""
import json
import math
from shapely.geometry import LineString, Point

RIVER = [(219.5,496.7),(337.7,496.7),(337.7,389.8),(368,389.8),
         (388,409.5),(428,409.5),(457,381),(474,381),(501,354.6),
         (544,354.6),(559,339.6),(648.8,339.6),(648.8,385.4),
         (678.5,385.4),(678.5,343.9),(717,343.9),(717,380.2),
         (779.8,380.2),(779.8,280.6),(827.2,280.6)]
PIERS = {
    '930GPUT':(415,409.5), '930GWRQ':(433,404.5), '930GPLW':(446,392),
    '930GCHP':(428,409.5), '930GBSE':(452,386), '930GBSP':(459,381),
    '930GSGW':(486,369), '930GMBK':(496,359), '930GWMR':(508,354.6),
    '930GWMP':(512,354.6), '930GEMB':(526,354.6), '930GBFR':(551,347.4),
    '930GSWK':(566,339.6), '930GLBR':(595.4725,339.6), '930GTMP':(604,339.6),
    '930GNEL':(648.8,359), '930GCAW':(648.8,359), '930GGLP':(648.8,373),
    '930GMHT':(656,385.4), '930GGNW':(674,385.4), '930GMIL':(693,343.9),
    '930GWRF':(717,367), '930GWAS':(748,380.2), '930GBRVS':(779.8,291),
}
# The terminal centres and route belong to this PDF, rather than the Tube-only
# layout. Greenwich Peninsula is on the south bank beside North Greenwich.
CABLE = [(700.91175,354.88075),(707.89,354.88075),
         (729.725,333.0455),(735.32275,333.0455)]

# Reviewed source bounds: the three route strokes, six decorative gondola
# pieces, two terminal rings, and each terminal's three walking dots.
CABLE_ARTWORK_BOXES = [
    (700.1984,333.0635,734.7794,354.9215),
    (718.6937,342.7735,721.7367,347.5935),
    (718.6506,342.5635,721.2676,345.1395),
    (718.6519,342.5638,721.4769,345.1818),
    (717.3256,347.1618,723.0276,352.3228),
    (719.6004,347.1711,723.0204,352.3131),
    (720.0300,347.6475,722.7030,350.1255),
    (699.4313,353.4003,702.3923,356.3613),
    (699.1364,353.1056,702.6874,356.6556),
    (698.7101,352.6671,699.7111,353.6691),
    (697.9540,351.9110,698.9550,352.9130),
    (697.1979,351.1549,698.1989,352.1569),
    (733.6982,331.4209,736.9472,334.6699),
    (733.3748,331.0974,737.2708,334.9934),
    (734.9770,330.2770,735.6850,330.9850),
    (734.9770,329.2080,735.6850,329.9160),
    (734.9770,328.1390,735.6850,328.8470),
]
CABLE_LABELS = [
    ('Greenwich',(700.0076,356.9181)), ('Peninsula',(700.0076,359.4056)),
    ('Royal',(737.5797,330.7157)), ('Docks',(737.5797,333.2032)),
]

# All 14 circled piers in the April 2026 reference, measured in PDF points.
# The sightseeing piers are map landmarks rather than live River Bus stops.
PIER_SYMBOLS = {
    'landmark:kingston-turks': ('Kingston Turks', (339.173,465.681)),
    'landmark:hampton-court': ('Hampton Court Pier', (331.693,495.140)),
    '930GCHP': ('Chelsea Harbour Pier', (425.818,407.713)),
    '930GEMB': ('Embankment Pier', (526.969,352.674)),
    '930GBSP': ('Battersea Power Station Pier', (459.081,382.781)),
    '930GSGW': ('Vauxhall St George Wharf Pier', (485.868,371.642)),
    '930GWMR': ('Westminster Pier', (508.622,352.674)),
    '930GWMP': ('London Eye Waterloo Pier', (508.611,356.562)),
    '930GBFR': ('Blackfriars Pier', (551.334,344.969)),
    '930GTMP': ('Tower Pier', (603.739,337.584)),
    '930GMIL': ('North Greenwich Pier', (699.607,346.209)),
    '930GGNW': ('Greenwich Pier', (668.538,387.720)),
    '930GWAS': ('Woolwich Arsenal Pier', (734.735,382.838)),
    '930GBRVS': ('Barking Riverside Pier', (787.502,278.177)),
}
STATION_ROUNDELS = {
    'nr:KNG': (347.624,474.126),
    '940GZZDLCUT': (673.324,392.303),
    '940GZZDLWLA': (738.917,386.899),
    '910GBARKRIV': (782.364,273.099),
    '940GZZLUNGW': (695.997,349.943),
    '910GCSEAH': (425.739,401.570),
    '940GZZLUWLO': (513.475,361.523),
    '940GZZLUWSM': (508.622,347.848),
    '940GZZLUEMB': (522.314,347.822),
    '940GZZBPSUST': (462.462,386.081),
    '940GZZLUBKF': (551.449,339.529),
    '940GZZDLTWG': (608.632,326.051),
    '940GZZLUTWH': (603.739,321.159),
    '940GZZLULNB': (568.904,362.37475),
    '940GZZDLRVC': (735.33875,326.07825),
    '940GZZDLSHA': (636.546,326.05875),
    '940GZZDLLIM': (652.209,326.0185),
    '940GZZDLWFE': (658.619,326.057),
}
PIER_WALKING_POINTS = {
    'landmark:kingston-turks': [[(347.624,474.126)]],
    'landmark:hampton-court': [[(331.693,505.757)]],
    '930GCHP': [[STATION_ROUNDELS['910GCSEAH']]],
    '930GEMB': [[STATION_ROUNDELS['940GZZLUEMB']]],
    '930GBSP': [[STATION_ROUNDELS['940GZZBPSUST']]],
    '930GSGW': [[(485.781,393.888)]],
    '930GWMR': [[STATION_ROUNDELS['940GZZLUWSM']]],
    '930GWMP': [[STATION_ROUNDELS['940GZZLUWLO']]],
    '930GBFR': [[STATION_ROUNDELS['940GZZLUBKF']]],
    '930GTMP': [[STATION_ROUNDELS['940GZZLUTWH']],
               [(608.632,332.691),STATION_ROUNDELS['940GZZDLTWG']]],
    '930GMIL': [[STATION_ROUNDELS['940GZZLUNGW']]],
    '930GGNW': [[STATION_ROUNDELS['940GZZDLCUT']]],
    '930GWAS': [[STATION_ROUNDELS['940GZZDLWLA']]],
    '930GBRVS': [[STATION_ROUNDELS['910GBARKRIV']]],
}
SYMBOL_BLUE = (.16548,.20073,.55415)

def _shape_bounds(shape):
    points = [p for command in shape['commands'] for p in command.values() if isinstance(p,dict)]
    return (min(p['x'] for p in points),min(p['y'] for p in points),
            max(p['x'] for p in points),max(p['y'] for p in points)) if points else None

def is_imported_boat(shape):
    """Identify the repeated ferry glyph, including the seven bare label icons."""
    fill = shape.get('fill')
    bounds = _shape_bounds(shape)
    return (fill is not None and max(abs(a-b) for a,b in zip(fill,SYMBOL_BLUE)) < .0001
            and bounds is not None and 50 <= len(shape['commands']) <= 80
            and 11 < bounds[2]-bounds[0] < 13 and 5 < bounds[3]-bounds[1] < 7)

def normalize_river_piers(document, pack):
    """Replace every imported pier with a native symbol at the source location.

    Move the reference's walking dots into the pier layer as well, including
    Tower Gateway's bent link, so hiding piers also hides their connections.
    """
    artwork = document['referenceArtwork']
    centres = [pack(position) for _,position in PIER_SYMBOLS.values()]
    def imported_symbol(shape):
        if is_imported_boat(shape): return True
        bounds = _shape_bounds(shape)
        fill = shape.get('fill')
        if not bounds or fill is None: return False
        blue = max(abs(a-b) for a,b in zip(fill,SYMBOL_BLUE)) < .0001
        white = min(fill) > .999
        if not (blue or white) or not (12 < bounds[2]-bounds[0] < 16 and 12 < bounds[3]-bounds[1] < 16):
            return False
        centre = ((bounds[0]+bounds[2])/2,(bounds[1]+bounds[3])/2)
        return any(math.dist(centre,(p['x'],p['y'])) < .02 for p in centres)
    artwork['shapes'] = [s for s in artwork['shapes'] if not imported_symbol(s)]
    walking_links = {link['pierID']:link['shapes'] for link in artwork.get('riverWalkingLinks',[])}
    def on_walking_link(shape):
        fill = shape.get('fill')
        bounds = _shape_bounds(shape)
        if (fill is None or max(fill) > .2 or not bounds
                or any(c['op']=='cubic' for c in shape['commands'])
                or not (.6 < bounds[2]-bounds[0] < 4.5 and .6 < bounds[3]-bounds[1] < 4.5)):
            return None
        centre = Point((bounds[0]+bounds[2])/2,(bounds[1]+bounds[3])/2)
        for pier_id,branches in PIER_WALKING_POINTS.items():
            start = PIER_SYMBOLS[pier_id][1]
            for branch in branches:
                points = [pack(p) for p in [start]+branch]
                path = LineString([(p['x'],p['y']) for p in points])
                if path.distance(centre) < 1:
                    return pier_id
        return None
    retained = []
    for shape in artwork['shapes']:
        pier_id = on_walking_link(shape)
        if pier_id is None: retained.append(shape)
        else: walking_links.setdefault(pier_id,[]).append(shape)
    artwork['shapes'] = retained
    artwork['riverWalkingLinks'] = [dict(pierID=k,shapes=v) for k,v in walking_links.items()]
    line = LineString(RIVER)
    anchors = {a['id']:a for a in artwork['riverAnchors']}
    artwork['additionalRiverPiers'] = []
    for pier_id,(name,position) in PIER_SYMBOLS.items():
        centre = pack(position)
        if pier_id not in anchors:
            artwork['additionalRiverPiers'].append(dict(id=pier_id,name=name,centre=centre))
            continue
        river_point = line.interpolate(line.project(Point(position)))
        river = pack((river_point.x,river_point.y))
        anchors[pier_id].update(x=river['x'],y=river['y'],
            offsetX=round(centre['x']-river['x'],3),offsetY=round(centre['y']-river['y'],3),
            walkingLinksInArtwork=True)
    for marker in document['stationMarkers']:
        if marker['stationID'] not in STATION_ROUNDELS: continue
        # Once source symbols have been reviewed, their recovered centres are
        # more precise than the hand-measured landmark coordinates below.
        if artwork.get('stationTicks') is not None: continue
        marker['anchor'] = pack(STATION_ROUNDELS[marker['stationID']])
        marker['primitives'] = [dict(kind='circle',circle=dict(
            centre=marker['anchor'],radius=5.922,outlineWidth=2.356))]
        if marker['stationID'] == '940GZZLULNB':
            # The Jubilee circle sits north-west of the Northern circle.
            marker['primitives'].append(dict(kind='circle',circle=dict(
                centre=pack((566.277,359.74775)),radius=5.922,outlineWidth=2.356)))
    # A direct diagonal would follow the Northern track. Use a 45-degree leg
    # parallel to it, then a short horizontal approach to the visible circle.
    pier = anchors['930GLBR']
    station = pack(STATION_ROUNDELS['940GZZLULNB'])
    bank_y = pier['y'] + pier['offsetY']
    via = dict(x=round(station['x']+22,3),y=station['y'])
    pier.update(x=round(via['x'] + via['y'] - bank_y,3),offsetX=0,
                walkingLinkVia=[via],labelSide=-1)
    # Move the source station label right of the final leg, together with its
    # semantic/accessibility label and tap rectangle. Keep rebuilds idempotent.
    positions = {'London':(571.3552,361.0306),'Bridge':(571.3552,363.5182)}
    for label in artwork['texts']:
        if label['text'] not in positions: continue
        source = pack(positions[label['text']])
        if math.dist((label['position']['x'],label['position']['y']),
                     (source['x'],source['y'])) < .015:
            label['position']['x'] = round(source['x']+28,3)
    label_centre = pack((582.7911377,363.7286682))
    london_bridge_ids = {m['stationID'] for m in document['stationMarkers'] if m['name'] == 'London Bridge'}
    for label in document['labels']:
        if label['stationID'] in london_bridge_ids: label['position'] = label_centre
    for label in artwork.get('stationLabels',[]):
        if label['stationID'] in london_bridge_ids: label['centre'] = label_centre

def normalize_cable_car(document, pack):
    """Give the native cable layer sole ownership of its route and terminals."""
    artwork = document['referenceArtwork']
    boxes = []
    for x0,y0,x1,y1 in CABLE_ARTWORK_BOXES:
        a,b = pack((x0,y0)),pack((x1,y1))
        boxes.append((a['x'],a['y'],b['x'],b['y']))
    retained,indices = [],{}
    for index,shape in enumerate(artwork['shapes']):
        bounds = _shape_bounds(shape)
        if bounds and any(max(abs(a-b) for a,b in zip(bounds,box)) < .015 for box in boxes):
            continue
        indices[index] = len(retained)
        retained.append(shape)
    artwork['shapes'] = retained
    # Physical station targets refer to source shape indices. Preserve those
    # references when applying this normalization to an already built asset.
    for target in artwork.get('stationRoundels',[]):
        target['sourceShapeIndex'] = indices[target['sourceShapeIndex']]
    labels = [(text,pack(position)) for text,position in CABLE_LABELS]
    artwork['texts'] = [label for label in artwork['texts'] if not any(
        label['text'] == text and math.dist(
            (label['position']['x'],label['position']['y']),(point['x'],point['y'])) < .015
        for text,point in labels)]

def add_landmarks(artwork, root, pack):
    line=LineString(RIVER)
    anchors=json.loads((root/'TubeTrackUK/Resources/RiverSchematic.json').read_text())
    for anchor in anchors:
        position=line.interpolate(line.project(Point(PIERS[anchor['id']])))
        centre=pack((position.x,position.y))
        anchor.update(x=centre['x'],y=centre['y'],offsetX=anchor['offsetX']*.65,offsetY=anchor['offsetY']*.65)
    artwork.update(riverAnchors=anchors,riverPath=[pack(p) for p in RIVER],
                   cableCarPoints=[pack(p) for p in CABLE],
                   cableCarAnchors={'940GZZALGWP':pack(CABLE[0]),'940GZZALRDK':pack(CABLE[-1])})
