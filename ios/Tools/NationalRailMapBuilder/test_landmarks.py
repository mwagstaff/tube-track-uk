"""Keep rebuilt pier symbols consistent with the reviewed bundled map."""
import copy
import json
import unittest
from pathlib import Path

from landmarks import (CABLE_ARTWORK_BOXES, _shape_bounds,
                       add_landmarks, normalize_river_piers, normalize_cable_car)

ROOT = Path(__file__).resolve().parents[2]


class PierLandmarkTests(unittest.TestCase):
    def test_rebuild_preserves_reviewed_native_piers_and_source_walking_links(self):
        document = json.loads((ROOT / 'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json').read_text())
        rebuilt = copy.deepcopy(document)
        def pack(point):
            return dict(x=round((point[0]-219)*4,3),y=round((point[1]-79)*4,3))
        add_landmarks(rebuilt['referenceArtwork'],ROOT,pack)
        normalize_river_piers(rebuilt,pack)
        normalize_cable_car(rebuilt,pack)
        self.assertEqual(rebuilt,document)
        normalize_river_piers(rebuilt,pack)
        normalize_cable_car(rebuilt,pack)
        self.assertEqual(rebuilt,document)
        self.assertEqual(len(rebuilt['referenceArtwork']['additionalRiverPiers']),2)
        self.assertEqual(sum(a.get('walkingLinksInArtwork') is True
                             for a in rebuilt['referenceArtwork']['riverAnchors']),12)

    def test_cable_artwork_is_removed_and_station_shape_indices_stay_valid(self):
        artwork = json.loads((ROOT / 'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json').read_text())['referenceArtwork']
        boxes = [tuple((v-(219 if i%2 == 0 else 79))*4 for i,v in enumerate(box))
                 for box in CABLE_ARTWORK_BOXES]
        for shape in artwork['shapes']:
            bounds = _shape_bounds(shape)
            self.assertFalse(bounds and any(max(abs(a-b) for a,b in zip(bounds,box)) < .015
                                           for box in boxes))
        for target in artwork['stationRoundels']:
            self.assertEqual(artwork['shapes'][target['sourceShapeIndex']]['fill'],[1,1,1])

    def test_london_bridge_pier_has_a_45_degree_link_on_the_south_bank(self):
        document = json.loads((ROOT / 'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json').read_text())
        pier = next(a for a in document['referenceArtwork']['riverAnchors'] if a['id']=='930GLBR')
        marker = next(m for m in document['stationMarkers'] if m['stationID']=='940GZZLULNB')
        x,y = pier['x']+pier['offsetX'],pier['y']+pier['offsetY']
        self.assertGreater(pier['offsetY'],0)
        self.assertGreater(x,marker['anchor']['x'])
        via = pier['walkingLinkVia'][0]
        self.assertAlmostEqual(x-via['x'],via['y']-y,places=3)
        self.assertEqual(via['y'],marker['anchor']['y'])
        self.assertGreater(via['x'],marker['anchor']['x']+14)
        label = next(l for l in document['referenceArtwork']['stationLabels'] if l['stationID']=='940GZZLULNB')
        self.assertGreater(label['centre']['x']-label['size']['width']/2,via['x']+4)
        self.assertEqual(pier['walkingLinkStationIDs'],['940GZZLULNB'])


if __name__ == '__main__':
    unittest.main()
