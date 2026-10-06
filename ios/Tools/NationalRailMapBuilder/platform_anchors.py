"""Supplement sparse station anchors by splitting existing OSM track edges.

TrainTrack's four diverse anchors sometimes omit the other passenger track at
a platform. We retain its graph and weighted router, adding platform-local
projections only for the reviewed stations below. No straight route fallback.
"""
from collections import defaultdict
from shapely.geometry import LineString, Point
from shapely.ops import substring
from shapely.strtree import STRtree

from route_national_rail_geography import distance_m

REVIEWED_STATIONS = {'EXR', 'HHY', 'LEB', 'SRA', 'ANZ', 'PNW'}

def supplement_platform_anchors(router, catalogue):
    # Local metric projection is sufficient for candidate selection; final
    # lengths and split costs use the original track geometry.
    sx, sy = 69_300, 111_200
    geometries = [LineString([(p[0]*sx,p[1]*sy) for p in e['p']]) for e in router.edges]
    tree = STRtree(geometries)
    cuts = defaultdict(list)
    for crs in sorted(REVIEWED_STATIONS):
        station=catalogue[crs]
        if crs == 'LEB': router.anchors[crs] = []
        point=Point(float(station['longitude'])*sx,float(station['latitude'])*sy)
        radius = 200
        for index in tree.query(point.buffer(radius)):
            line=geometries[index]
            distance=line.distance(point)
            if distance>radius or line.length==0: continue
            measure=line.project(point)
            cuts[int(index)].append((measure,crs,distance))
    for index, candidates in cuts.items():
        edge=router.edges[index]; line=geometries[index]
        boundaries=[(0,edge['s'])]
        for measure,crs,distance in sorted(candidates):
            if measure<.05: node=edge['s']
            elif line.length-measure<.05: node=edge['e']
            else:
                projected=line.interpolate(measure)
                node=len(router.nodes)
                router.nodes.append((projected.x/sx,projected.y/sy))
                router.adjacency.append([])
                boundaries.append((measure,node))
            router.anchors[crs].append({'n':node,'d':distance})
        boundaries.append((line.length,edge['e']))
        for (a,start),(b,end) in zip(boundaries,boundaries[1:]):
            if b-a<.001: continue
            track=[(x/sx,y/sy) for x,y in substring(line,a,b).coords]
            cost=edge['c']*((b-a)/line.length)
            new_index=len(router.edges)
            router.edges.append({'s':start,'e':end,'c':cost,'p':track})
            router.adjacency[start].append((end,new_index))
            router.adjacency[end].append((start,new_index))
