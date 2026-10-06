"""Reviewed river/cable coordinates in the combined PDF's page space.

The original Tube map has different geometry. These anchors retain existing
pier/boat/terminal interactions when switching to the combined artwork.
"""
import json
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
    '930GSWK':(566,339.6), '930GLBR':(580,339.6), '930GTMP':(604,339.6),
    '930GNEL':(648.8,359), '930GCAW':(648.8,359), '930GGLP':(648.8,373),
    '930GMHT':(656,385.4), '930GGNW':(674,385.4), '930GMIL':(693,343.9),
    '930GWRF':(717,367), '930GWAS':(748,380.2), '930GBRVS':(779.8,291),
}
CABLE = [(710.3,339.1),(713.8,339.1),(721.8,331.1),(735.2,331.1)]

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
