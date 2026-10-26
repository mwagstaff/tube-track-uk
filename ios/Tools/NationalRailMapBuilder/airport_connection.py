"""Make the existing DART terminal artwork an informational station target.

This is deliberately absent from the rail CRS/departure catalogue: it opens
connection information, not a Darwin departure board.
"""
def add_airport_connection(document, metadata):
    sid = 'nr:LUA'
    centre = dict(x=1037.888, y=58.266)
    label = dict(x=1039.348, y=45.258)
    # The old Parkway label target incorrectly covered the airport's text.
    # Bind Parkway to its own two-line label west of the terminal.
    for item in document['labels']:
        if item.get('stationID') == 'nr:LTN':
            item['position'] = dict(x=973.26, y=72.475)
    for item in document['referenceArtwork']['stationLabels']:
        if item['stationID'] == 'nr:LTN':
            item['centre'] = dict(x=973.26, y=72.475)
            item['size'] = dict(width=64, height=22)
    if any(s['id'] == sid for s in metadata['stations']):
        return
    metadata['stations'].append(dict(
        id=sid, name='Luton Airport', latitude=51.8798, longitude=-0.3765,
        schematicX=centre['x'], schematicY=centre['y'], lineIDs=[],
        interchange=False, searchAliases=['Luton Airport', 'Luton DART', 'LUA'], hubID=None))
    document['stationMarkers'].append(dict(
        stationID=sid, name='Luton Airport', lineIDs=[], anchor=centre, hitRadius=12,
        primitives=[dict(kind='circle', circle=dict(centre=centre, radius=5.92, outlineWidth=1.5))]))
    document['labels'].append(dict(
        id='rail-label:'+sid, stationID=sid, text='Luton Airport', position=label,
        alignment='centre', rotationDegrees=0, priority=10, visibilityTier='network'))
    artwork = document['referenceArtwork']
    artwork['stationLabels'].append(dict(stationID=sid, centre=label, size=dict(width=67, height=11)))
    # Resolve the actual white terminal circle, keeping the source index valid
    # if the vector extraction changes its ordering.
    for index, shape in enumerate(artwork['shapes']):
        if len(shape['commands']) != 5 or not shape['fill'] or min(shape['fill']) < .98:
            continue
        points = [c[k] for c in shape['commands'] for k in ('to', 'control1', 'control2') if k in c]
        xs, ys = [p['x'] for p in points], [p['y'] for p in points]
        if abs((min(xs)+max(xs))/2-centre['x']) < .02 and abs((min(ys)+max(ys))/2-centre['y']) < .02:
            artwork['stationRoundels'].append(dict(
                stationID=sid, centre=centre, radius=(max(xs)-min(xs))/2, sourceShapeIndex=index))
            return
    raise ValueError('Luton DART terminal circle missing from reference artwork')
