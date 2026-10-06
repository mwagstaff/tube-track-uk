#!/usr/bin/env python3
"""Build the optional London Rail & Tube layer from the April 2026 reference.

Requires PyMuPDF and Shapely. Uses TrainTrack UK's station catalogue and OSM routing asset;
routes.json records the mapped corridors, not a timetable or stopping pattern.
Run with --pdf PATH --train-track PATH. No network requests are made by this tool.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
import sys
from pathlib import Path

import pymupdf

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/TubeGraphBuilder"))
from route_national_rail_geography import RailwayGraph, ROUTING_ASSET, distance_m

CROP = pymupdf.Rect(219, 79, 829, 635)
SCALE = 4
LEGEND_Y = dict(zip([
    'chiltern-railways', 'c2c', 'east-midlands-railway', 'gatwick-express',
    'great-northern', 'great-western-railway', 'greater-anglia', 'heathrow-express',
    'london-northwestern-railway', 'south-western-railway', 'southeastern',
    'southeastern-high-speed', 'southern',
], [343.104,349.448,355.133,361.209,367.569,373.645,379.721,385.797,391.873,404.070,410.146,416.222,422.388]))
LEGEND_Y['thameslink-extension'] = 428.464
NAMES = {'thameslink-extension':'Thameslink', 'c2c':'c2c', 'great-western-railway':'Great Western Railway',
         'london-northwestern-railway':'London Northwestern Railway',
         'southeastern-high-speed':'Southeastern high speed'}
ALIASES = {
    'St Albans City':'St Albans',
    'Kings Cross': 'London Kings Cross', 'St Pancras International': 'London St Pancras International',
    'Heathrow Terminals 2 & 3':'Heathrow Terminals 1-2-3 Rail',
    'Heathrow Terminal 5':'Heathrow Terminal 5 Rail',
    'Kensington (Olympia)':'Kensington Olympia',
}
PDF_NAMES = {
    'Harrow-on-the-Hill': 'Harrow- on-the-Hill',
    "King's Cross St. Pancras": 'King’s Cross',
    'London Paddington': 'Paddington',
    'Paddington (H&C Line)-Underground': 'Paddington',
    'New Cross ELL': 'New Cross',
    'Queens Park (London)': 'Queen’s Park',
    "St. James's Park": 'St James’s Park',
    "St. John’s Wood": 'St John’s Wood',
    "St. John's Wood": 'St John’s Wood',
    "St. Paul's": 'St Paul’s',
    'Walthamstow Queens Road': 'Walthamstow Queen’s Road',
    'Bromley-by-Bow': 'Bromley- by-Bow',
    'Cutty Sark (for Maritime Greenwich) DLR Station':'Cutty Sark for Maritime Greenwich',
    'Kings Cross': 'King’s Cross', 'Queens Road Peckham': 'Queens Road Peckham',
    'Shepherds Bush': 'Shepherd’s Bush', 'St Pancras International':'St Pancras International',
    'Heathrow Terminals 2 & 3':'Heathrow Terminals 2 & 3',
    'Chafford Hundred':'Chafford Hundred',
}
# Reviewed ambiguous labels beside another station's tick or a large hub.
ANCHORS = {
    'Notting Hill Gate': (428.336,316.006),
    'South Kensington': (447.393,346.176),
    'Highbury & Islington': (599.87,237.003),
    'Clapham High Street': (492.675,425.778),
    'Stratford': (710.67,243.1),
    "King's Cross St. Pancras": (544.25,262.5),
    'Euston': (514.116,263.466),
    'New Cross Gate': (631.465,423.489),
    'Northolt': (282.287,221.459),
    'Woolwich': (749.157,386.899),
}

def norm(value):
    value = re.sub(r'\([^)]*\)', '', value).lower().replace('&', 'and')
    value = re.sub(r' (rail|underground|dlr) station$| tram stop$', '', value)
    value = re.sub(r'^london ', '', value)
    return re.sub(r'[^a-z0-9]', '', value)

def point(p):
    return {'x': round((p[0]-CROP.x0)*SCALE, 3), 'y': round((p[1]-CROP.y0)*SCALE, 3)}

def commands(drawing):
    result = []
    last = None
    for item in drawing['items']:
        kind = item[0]
        if kind == 're':
            r = item[1]
            pts = [r.tl,r.tr,r.br,r.bl] if item[2] == 1 else [r.tl,r.bl,r.br,r.tr]
            result += [{'op':'move','to':point(pts[0])}] + [{'op':'line','to':point(p)} for p in pts[1:]] + [{'op':'close'}]
            last = None
        elif kind == 'qu':
            q = item[1]
            result += [{'op':'move','to':point(q.ul)}] + [{'op':'line','to':point(p)} for p in [q.ur,q.lr,q.ll]] + [{'op':'close'}]
            last = None
        else:
            if last is None or abs(last-item[1]) > .001:
                result.append({'op':'move','to':point(item[1])})
            if kind == 'l':
                result.append({'op':'line','to':point(item[2])})
                last = item[2]
            elif kind == 'c':
                result.append({'op':'cubic','control1':point(item[2]),'control2':point(item[3]),'to':point(item[4])})
                last = item[4]
            else:
                raise ValueError(f'Unknown PDF operation {kind}')
    if drawing.get('closePath'):
        result.append({'op':'close'})
    return result

def rgb(value):
    return [round(c, 5) for c in value] if value else None

def label_boxes(page, name):
    name = PDF_NAMES.get(name, re.sub(r'\s*\([^)]*\)', '', name))
    name = re.sub(r' (DLR|Rail|Underground) Station$', '', name).strip()
    options = [name, name.replace(' & ', ' and '), name.replace("'", '’')]
    found = []
    for option in options:
        hits = page.search_for(option, textpage=TEXT_PAGE)
        # search_for emits one rectangle per line of a wrapped label.
        groups = []
        for r in hits:
            if not CROP.contains(r):
                continue
            if groups and norm(page.get_textbox(groups[-1], textpage=TEXT_PAGE)) != norm(option) and -1 < r.y0-groups[-1].y1 < .6 and abs(r.x0-groups[-1].x0) < 20:
                groups[-1] |= r
            else:
                groups.append(pymupdf.Rect(r))
        for r in groups:
            spans = [s for s in SPANS if (r+(-.2,-.2,.2,.2)).intersects(pymupdf.Rect(s['bbox'])) and pymupdf.Rect(s['bbox']).get_area() > 0]
            # Reject substring hits such as Kenton inside South Kenton.
            if any((pymupdf.Rect(s['bbox']) & r).get_area() > r.get_area()*.6 and norm(option) in norm(s['text']) and norm(option)!=norm(s['text'])
                   and len(norm(s['text']))>len(norm(option))+1 for s in spans):
                continue
            # Exclude continuation destinations and fare-zone prose.
            if spans and any(2<s['size']<2.8 and s['color']==2301728 for s in spans):
                found.append(r)
        if found:
            break
    return found

def box_distance(p, r):
    return math.hypot(max(r.x0-p[0],0,p[0]-r.x1), max(r.y0-p[1],0,p[1]-r.y1))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdf',required=True,type=Path)
    parser.add_argument('--train-track',required=True,type=Path)
    parser.add_argument('--skip-routing',action='store_true',help='Inspect matching without producing assets')
    args=parser.parse_args()
    pdf=pymupdf.open(args.pdf); page=pdf[0]; drawings=page.get_drawings()
    global TEXT_PAGE, SPANS
    TEXT_PAGE=page.get_textpage(flags=pymupdf.TEXTFLAGS_SEARCH)
    SPANS=[s for b in page.get_text('dict', textpage=TEXT_PAGE)['blocks'] for l in b.get('lines',[]) for s in l['spans']]
    catalogue=json.loads((args.train_track/'api/train-track-api/resources/stations.json').read_text())
    # TrainTrack's LEB catalogue point is on the Gospel Oak–Barking corridor.
    # Verified against https://api.tfl.gov.uk/StopPoint/910GLEABDGE on 2026-10-06.
    for entry in catalogue:
        if entry['crs'] == 'LEB':
            entry.update(latitude='51.566548', longitude='-0.036673')
    base=json.loads((ROOT/'TubeTrackUK/Resources/TubeGraph.json').read_text())
    runs=json.loads(Path(__file__).with_name('routes.json').read_text())
    crs_index=json.loads((ROOT/'TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailStations.json').read_text())
    crs_index={sid:codes for sid,codes in crs_index.items() if not sid.startswith('nr:')}
    by_crs={s['crs']:s for s in catalogue}
    def station(name):
        name=ALIASES.get(name,name)
        exact=[s for s in catalogue if s['name'].lower()==name.lower()]
        matches=exact or [s for s in catalogue if norm(s['name'])==norm(name) and 50.9<float(s['latitude'])<52 and -.9<float(s['longitude'])<.6]
        if len(matches)!=1:
            raise ValueError(f'{name}: {[s["name"] for s in matches]}')
        return matches[0]
    rail={}
    for branch in sum(runs.values(),[]):
        for name in branch.split('|'):
            entry=station(name)
            rail[entry['crs']]=(name,entry)
    # Station glyphs: small filled tick rectangles and circular interchange rings.
    glyphs=[]
    for d in drawings:
        r=d['rect']; w,h=r.width,r.height
        if d['type']=='f' and d['fill'] and CROP.contains(r):
            is_interchange = max(d['fill'])<.2 and max(w,h)<35 and any(i[0]=='c' for i in d['items'])
            if .25<min(w,h) and ((min(w,h)<4.5 and max(w,h)<6 and sum(d['fill'])<2.6) or is_interchange):
                glyphs.append(((r.x0+r.x1)/2,(r.y0+r.y1)/2))
    all_stations=copy.deepcopy(base['stations'])
    station_records=[]; lookup={}; missing=[]
    for crs,(name,entry) in sorted(rail.items()):
        boxes=label_boxes(page,name)
        if not boxes:
            missing.append((name,crs)); continue
        # Prefer the whole name, preventing "Sutton" matching "Sutton Common".
        def rank(r):
            text=page.get_textbox(r+(-.2,-.1,.2,.1), textpage=TEXT_PAGE).replace('\n',' ')
            return (norm(text)!=norm(name), min(box_distance(p,r) for p in glyphs))
        box=min(boxes,key=rank)
        if name == 'St Margarets (Herts)': box=min(boxes,key=lambda r:r.y0)
        if name == 'St Margarets (London)': box=max(boxes,key=lambda r:r.y0)
        near=sorted(glyphs,key=lambda p:box_distance(p,box))
        anchor=near[0]
        # Reuse existing stop identity, favouring an actual CRS match over names.
        existing=[s for s in base['stations'] if crs in crs_index.get(s['id'],[]) and norm(s['name'])==norm(name)]
        if not existing and crs in {'KGX','NWX'}:
            existing=[s for s in base['stations'] if s['id'] == {'KGX':'940GZZLUKSX','NWX':'910GNWCRELL'}[crs]]
        if not existing:
            existing=[s for s in base['stations'] if norm(s['name'])==norm(name) and distance_m((float(entry['longitude']),float(entry['latitude'])),(s['longitude'],s['latitude']))<1200]
        representative=min(existing,key=lambda s:(not s['id'].startswith('910G'),s['id'])) if existing else None
        sid=representative['id'] if representative else f'nr:{crs}'
        if not representative:
            representative=dict(id=sid,name=re.sub(r'\s*\([^)]*\)', '', name),latitude=float(entry['latitude']),longitude=float(entry['longitude']),schematicX=point(anchor)['x'],schematicY=point(anchor)['y'],lineIDs=[],interchange=False,searchAliases=[entry['name'],crs,'National Rail'],hubID=None)
            all_stations.append(representative)
        lookup[crs]=sid
        crs_index[sid]=sorted(set(crs_index.get(sid,[])+[crs]))
        station_records.append(dict(id=sid,crs=crs,name=representative['name'],anchor=point(anchor),labelBox=[round(v,3) for v in box]))
    print('Rail catalogue:',len(rail),'matched:',len(lookup),'missing:',missing,flush=True)
    if missing or args.skip_routing:
        return 1 if missing else 0
    # All currently mapped TfL stations get anchors in the alternate layout.
    markers=[]; labels=[]; label_targets=[]; used_ids=set(); new_ids={s['id'] for s in all_stations if s['id'].startswith('nr:')}
    rail_positions={s['id']:s for s in station_records}
    for s in all_stations:
        record=rail_positions.get(s['id'])
        boxes=label_boxes(page,s['name']) if not record else [pymupdf.Rect(record['labelBox'])]
        if not boxes:
            continue
        box=min(boxes,key=lambda r:min(box_distance(p,r) for p in glyphs))
        anchor=record['anchor'] if record else point(min(glyphs,key=lambda p:box_distance(p,box)))
        plain_name=re.sub(r' (DLR|Rail|Underground) Station$', '', s['name'])
        if plain_name in ANCHORS:
            anchor=point(ANCHORS[plain_name])
            box=min(label_boxes(page,s['name']),key=lambda r:box_distance(ANCHORS[plain_name],r))
        markers.append(dict(stationID=s['id'],name=s['name'],lineIDs=s['lineIDs'],anchor=anchor,hitRadius=12,primitives=[dict(kind='circle',circle=dict(centre=anchor,radius=3.3,outlineWidth=1.5))]))
        labels.append(dict(id='rail-label:'+s['id'],stationID=s['id'],text=s['name'],position=point(((box.x0+box.x1)/2,(box.y0+box.y1)/2)),alignment='centre',rotationDegrees=0,priority=10,visibilityTier='network'))
        label_targets.append(dict(stationID=s['id'],centre=labels[-1]['position'],size=dict(width=round(box.width*SCALE,3),height=round(box.height*SCALE,3))))
        used_ids.add(s['id'])
    # Preserve the actual vector shapes and text, including limited-service styles.
    thames = next(d for d in drawings if d['fill'] and d['rect'].width>500
                  and .77<d['fill'][0]<.79 and d['fill'][2]>.98)
    tram_zone_color = next(d['fill'] for d in drawings if d['fill'] and d['rect'].width>150
                           and d['rect'].height>100 and .87<d['fill'][0]<.89
                           and .92<d['fill'][1]<.94 and .82<d['fill'][2]<.84)
    tram_zone_rects = [d['rect'] for d in drawings if d['fill']==tram_zone_color]
    shapes=[]
    for d in drawings:
        if not CROP.intersects(d['rect']+(-.01,-.01,.01,.01)): continue
        if d['rect'].x0>645 and d['rect'].y0>600: continue # reference publisher logos
        # Remove both the tram fare-zone fill and its separate white border.
        if any(all(abs(a-b)<.01 for a,b in zip(d['rect'],r)) for r in tram_zone_rects): continue
        # Remove unlabelled fare-zone bands; route styling is retained exactly.
        if d['fill'] and min(d['fill'])>.84 and max(d['fill'])-min(d['fill'])<.03 and d['rect'].get_area()>1000: continue
        # Remove the reference's map grid and outer frame.
        if d['type']=='s' and d['width'] and d['width']<.2 and d['color'] and d['color'][2]>.9: continue
        dash=re.search(r'\[([^]]*)\]',d.get('dashes') or '')
        shapes.append(dict(commands=commands(d),fill=rgb(d['fill']),stroke=rgb(d['color']),width=round((d['width'] or 0)*SCALE,3),dash=[round(float(v)*SCALE,3) for v in dash[1].split()] if dash else [],evenOdd=bool(d['even_odd'])))
        if d is thames: shapes[-1]['role']='waterway'
    texts=[]
    for b in page.get_text('dict')['blocks']:
        for l in b.get('lines',[]):
            for s in l['spans']:
                if not CROP.contains(pymupdf.Rect(s['bbox'])) or s['size']>8: continue
                if s['text'].strip() in 'ABCDEFGH123456789': continue
                if s['origin'][1]>570 and s['origin'][0]<372: continue # fares information panel
                if s['color']==7716163 and s['text'].strip() in {'London','Trams','fare zone'}: continue
                c=s['color']; color=[((c>>16)&255)/255,((c>>8)&255)/255,(c&255)/255]
                texts.append(dict(text=s['text'],position=point((s['bbox'][0],s['bbox'][1])),size=round(s['size']*SCALE,3),color=rgb(color)))
    # Remove the fares-panel shapes too; the app already has its own chrome.
    shapes=[s for s in shapes if not all(p['x']<612 and p['y']>1964 for c in s['commands'] for k,p in c.items() if isinstance(p,dict))]
    template=json.loads((ROOT/'TubeTrackUK/Resources/BeckMap/v1/full-underground.json').read_text())
    document={k:copy.deepcopy(template[k]) for k in ['schemaVersion','geometryStatus','source','styles','debugReference']}
    document.update(identifier='london-rail-and-tube-april-2026',artworkSize=dict(width=CROP.width*SCALE,height=CROP.height*SCALE),paths=[],segments=[],stationMarkers=markers,labels=labels,routes=[],supportedLineIDs=[l['id'] for l in base['lines']],referenceArtwork=dict(shapes=shapes,texts=texts))
    document['source']['note']='London Rail & Tube services, TfL and Rail Delivery Group, April 2026. Vector geometry retained; interactive stations joined by CRS.'
    document['referenceArtwork']['stationLabels']=label_targets
    for key in document['styles']:
        document['styles'][key]=round(document['styles'][key]*.55,3)
    from landmarks import add_landmarks
    add_landmarks(document['referenceArtwork'], ROOT, point)
    from paper_routes import add_semantic_routes
    paper_failures=add_semantic_routes(document,base,page,drawings,CROP,SCALE)
    Path('/tmp/tubetrack-paper-failures.json').write_text(json.dumps(paper_failures,indent=2))
    if paper_failures or len(markers)!=len(all_stations):
        raise ValueError('Incomplete combined map station/segment coverage')
    # Reuse the reviewed OSM graph and station-anchor router already used for Thameslink.
    print('Loading OSM railway graph…',flush=True)
    router=RailwayGraph(json.loads((args.train_track/ROUTING_ASSET).read_text()))
    from platform_anchors import supplement_platform_anchors
    supplement_platform_anchors(router, by_crs)
    routes=[]; cache={}; errors=[]
    for line,branches in runs.items():
        color=next(d['color'] for d in drawings if d['color'] and d['rect'].x0<75 and d['rect'].x1>85 and abs(d['rect'].y0-LEGEND_Y[line])<.2)
        pairs=set()
        for branch in branches:
            crss=[station(n)['crs'] for n in branch.split('|')]
            for a,b in zip(crss,crss[1:]): pairs.add(tuple(sorted((a,b))))
        for a,b in sorted(pairs):
            if (a,b) not in cache:
                geometry=router.route(a,b)
                if geometry is None:
                    errors.append(f'{line}: no OSM route {a}–{b}'); continue
                length=sum(distance_m(x,y) for x,y in zip(geometry,geometry[1:]))
                start,end=by_crs[a],by_crs[b]
                direct=distance_m((float(start['longitude']),float(start['latitude'])),(float(end['longitude']),float(end['latitude'])))
                if length>max(direct*2.2,direct+800):
                    errors.append(f'{line}: detour {a}–{b}: {length:.0f}m vs {direct:.0f}m'); continue
                cache[a,b]=[dict(latitude=round(lat,6),longitude=round(lon,6)) for lon,lat in geometry]
            routes.append(dict(id=f'{line}:{a}:{b}',operatorID=line,name=NAMES.get(line,line.replace('-',' ').title()),color=rgb(color),fromStationID=lookup[a],toStationID=lookup[b],geographicPoints=cache[a,b]))
        print(line,len(pairs),'segments',flush=True)
    if errors:
        print('\n'.join(errors));return 1
    metadata=dict(schemaVersion=1,referenceURL='https://content.tfl.gov.uk/london-rail-and-tube-services-map.pdf',referenceSHA256=hashlib.sha256(args.pdf.read_bytes()).hexdigest(),referenceRevision='April 2026',attribution='Transport for London and Rail Delivery Group; © OpenStreetMap contributors, ODbL 1.0',stations=[s for s in all_stations if s['id'] in new_ids],stationRecords=station_records,routes=routes)
    metadata['routingSHA256']=hashlib.sha256((args.train_track/ROUTING_ASSET).read_bytes()).hexdigest()
    metadata['catalogueSHA256']=hashlib.sha256((args.train_track/'api/train-track-api/resources/stations.json').read_bytes()).hexdigest()
    (ROOT/'TubeTrackUK/Resources/NationalRailMap.json').write_text(json.dumps(metadata,separators=(',',':'))+'\n')
    (ROOT/'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json').write_text(json.dumps(document,separators=(',',':'))+'\n')
    (ROOT/'TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailStations.json').write_text(json.dumps(dict(sorted(crs_index.items())),indent=2)+'\n')
    print(f'Wrote {len(new_ids)} new stations, {len(routes)} routes, {len(markers)} interactive markers, {len(shapes)} vector shapes.')
    return 0

if __name__=='__main__':
    raise SystemExit(main())
