"""Project existing TfL semantic segments onto the combined map's vector tracks."""
import heapq
import math
from collections import defaultdict

from shapely.geometry import LineString, Point
from shapely.ops import unary_union


def polylines(drawing):
    points=[]
    for item in drawing['items']:
        if item[0] not in ('l','c'): continue
        if points and math.dist(points[-1],item[1])>.01:
            if len(points)>1: yield points
            points=[]
        if not points: points.append(tuple(item[1]))
        if item[0]=='l':
            a,b=item[1:]; steps=max(1,math.ceil(abs(b-a)/.6))
            points.extend(tuple(a[j]+(b[j]-a[j])*i/steps for j in [0,1]) for i in range(1,steps+1))
        else:
            a,b,c,d=item[1:]
            steps=max(4,math.ceil((abs(a-b)+abs(b-c)+abs(c-d))/.6))
            for i in range(1,steps+1):
                t=i/steps;u=1-t
                points.append(tuple(u*u*u*a[j]+3*u*u*t*b[j]+3*u*t*t*c[j]+t*t*t*d[j] for j in [0,1]))
    if len(points)>1: yield points


def add_semantic_routes(document, base, page, drawings, crop, scale):
    markers={m['stationID']:m for m in document['stationMarkers']}
    def raw(p):return (p['x']/scale+crop.x0,p['y']/scale+crop.y0)
    def packed(p):return dict(x=round((p[0]-crop.x0)*scale,3),y=round((p[1]-crop.y0)*scale,3))
    failures=[]
    for line in base['lines']:
        name={'tram':'London Trams'}.get(line['id'],line['name'])
        labels=[r for r in page.search_for(name) if 85<r.x0<120 and 170<r.y0<435]
        if not labels:
            failures.append((line['id'],'legend'));continue
        y=(labels[0].y0+labels[0].y1)/2
        legend=[d for d in drawings if d['color'] and d['rect'].x0<75 and d['rect'].x1>85 and abs(d['rect'].y0-y)<3]
        if not legend: failures.append((line['id'],'color'));continue
        color=min(legend,key=lambda d:abs(d['rect'].y0-y))['color']
        strokes=[d for d in drawings if d['color']==color and d['width'] and d['width']>.6 and crop.intersects(d['rect']+(-.01,-.01,.01,.01))]
        # Northern and Gatwick Express share ink, but use different casing widths.
        if line['id']=='northern':strokes=[d for d in strokes if abs(d['width']-1.245)<.01]
        pieces=[LineString(p) for d in strokes for p in polylines(d) if len(set(p))>1]
        if not pieces:failures.append((line['id'],'tracks'));continue
        network=unary_union(pieces)
        components=list(network.geoms) if hasattr(network,'geoms') else [network]
        nodes=[];ids={};adj=defaultdict(list)
        def node(p):
            key=(round(p[0],1),round(p[1],1))
            if key not in ids:ids[key]=len(nodes);nodes.append(tuple(p))
            return ids[key]
        for part in components:
            pts=list(part.coords)
            for a,b in zip(pts,pts[1:]):
                i,j=node(a),node(b);cost=math.dist(a,b)
                adj[i].append((j,cost));adj[j].append((i,cost))
        # The artwork can split a continuous track at a join underneath a roundel.
        endpoints=[i for i in range(len(nodes)) if len(adj[i])==1]
        for i in endpoints:
            # Exclude only neighbours already reached locally. A broken join
            # can still belong to the same component via a long loop.
            local={i:0}; pending=[(0,i)]
            while pending:
                cost,j=heapq.heappop(pending)
                for k,w in adj[j]:
                    c=cost+w
                    if c<8 and c<local.get(k,math.inf): local[k]=c;heapq.heappush(pending,(c,k))
            candidates=sorted((math.dist(nodes[i],p),j) for j,p in enumerate(nodes) if j not in local)
            for cost,j in candidates[:1]:
                if cost<4.5:adj[i].append((j,cost));adj[j].append((i,cost))
        def route(a,b):
            start=min(range(len(nodes)),key=lambda i:math.dist(nodes[i],a))
            end=min(range(len(nodes)),key=lambda i:math.dist(nodes[i],b))
            q=[(0,start)];costs={start:0};prev={}
            while q:
                cost,i=heapq.heappop(q)
                if cost>costs[i]:continue
                if i==end:
                    chain=[i]
                    while i!=start:i=prev[i];chain.append(i)
                    return [nodes[i] for i in reversed(chain)]
                for j,w in adj[i]:
                    c=cost+w
                    if c<costs.get(j,math.inf):costs[j]=c;prev[j]=i;heapq.heappush(q,(c,j))
            return None
        for segment in base['segments']:
            if segment['lineID']!=line['id']:continue
            a,b=segment['fromStationID'],segment['toStationID']
            if a not in markers or b not in markers:failures.append((segment['id'],'station'));continue
            def station_port(sid):
                if sid=='940GZZLUKSX' and line['id'] in ('circle','hammersmith-city','metropolitan'):
                    return (544.25,269.24)
                if sid=='940GZZLUEUS' and line['id']=='northern' and (b if sid==a else a) in ('940GZZLUKSX','940GZZLUCTN'):
                    return (528.297,263.466)
                return raw(markers[sid]['anchor'])
            points=route(station_port(a),station_port(b))
            if not points or len(points)<2:failures.append((segment['id'],'path'));continue
            # Keep semantic ports on the actual line; multi-line circles can span
            # several parallel paths around a single shared station anchor.
            path_id='combined:'+segment['id']
            document['paths'].append(dict(id=path_id,commands=[dict(op='move' if i==0 else 'line',to=packed(p)) for i,p in enumerate(points)]))
            document['segments'].append(dict(id=segment['id'],lineID=line['id'],fromStationID=a,toStationID=b,pathID=path_id,translation=dict(x=0,y=0),pathDirection='forward',fromPort=packed(points[0]),toPort=packed(points[-1])))
    print('Combined semantic paths:',len(document['segments']),'unmatched:',len(failures),flush=True)
    return failures
