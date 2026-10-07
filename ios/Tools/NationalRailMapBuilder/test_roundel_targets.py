"""Regression checks for the reference artwork's physical departure targets.

Run with the same PyMuPDF/Shapely environment used by build.py:
    python -m unittest discover -s ios/Tools/NationalRailMapBuilder
"""
import json
import math
import unittest
from pathlib import Path

import build
from roundel_targets import (AIRPORT_TRANSFER_CENTRES, CABLE_TERMINAL_CENTRES,
                             OPERATOR_CODES, REVIEWED_ROUNDELS, extract_roundels)


class RoundelTargetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = build.ROOT / 'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json'
        cls.artwork = json.loads(path.read_text())['referenceArtwork']
        cls.targets = cls.artwork['stationRoundels']

    def test_every_visible_rail_circle_has_one_departure_target(self):
        circles = extract_roundels(self.artwork['shapes'])
        # Cable terminals are now supplied by the native cable-car layer.
        self.assertEqual(len(circles), 375)
        self.assertEqual(len(self.targets), 374)
        exclusions = CABLE_TERMINAL_CENTRES + AIRPORT_TRANSFER_CENTRES
        for circle in circles:
            if any(math.dist(circle['point'], p) < .02 for p in exclusions):
                continue
            hits = [target for target in self.targets if math.dist(circle['point'],
                    (target['centre']['x'],target['centre']['y'])) < .02]
            self.assertEqual(len(hits), 1, circle)
            self.assertEqual(hits[0]['sourceShapeIndex'],circle['sourceShapeIndex'])

    def test_compound_interchange_outlines_have_individual_circles(self):
        for station_id, services in [('940GZZLUBND', {'central','jubilee'}),
                                     ('940GZZLUTCR', {'central','northern'})]:
            targets = [t for t in self.targets if t['stationID']==station_id]
            self.assertEqual({t['lineID'] for t in targets},services)
            self.assertEqual(len({t['sourceShapeIndex'] for t in targets}),1)

    def test_shadwell_limehouse_and_neighbouring_dlr_roundels_keep_their_station(self):
        # Independently measured source circles, including the separate Shadwell
        # Overground circle and the shared DLR/rail circle at Limehouse.
        expected = [
            ((1650.312,968.363),'910GSHADWEL','windrush'),
            ((1670.184,988.235),'940GZZDLSHA','dlr'),
            ((1732.836,988.074),'940GZZDLLIM','dlr'),
            ((1758.476,988.228),'940GZZDLWFE','dlr'),
            ((1839.157,988.208),'940GZZDLPOP','dlr'),
            ((1817.276,1024.169),'940GZZDLWIQ','dlr'),
            ((1817.276,1064.357),'940GZZDLCAN','dlr'),
        ]
        for centre,station_id,line_id in expected:
            target = min(self.targets,key=lambda t:math.dist(centre,(t['centre']['x'],t['centre']['y'])))
            self.assertLess(math.dist(centre,(target['centre']['x'],target['centre']['y'])),.02)
            self.assertEqual(target['stationID'],station_id)
            self.assertEqual(target['lineID'],line_id)
        dlr_targets = [t['stationID'] for t in self.targets if t.get('lineID')=='dlr']
        self.assertEqual(len(dlr_targets),len(set(dlr_targets)))

    def test_reviewed_ambiguous_labels_keep_their_correct_station_and_service(self):
        for centre,(station_id,service) in REVIEWED_ROUNDELS.items():
            target = min(self.targets,key=lambda t:math.dist(centre,(t['centre']['x'],t['centre']['y'])))
            self.assertLess(math.dist(centre,(target['centre']['x'],target['centre']['y'])),.02)
            self.assertEqual(target['stationID'],station_id)
            if service in OPERATOR_CODES:
                self.assertEqual(target['operatorID'],'national-rail:'+OPERATOR_CODES[service])
            else:
                self.assertEqual(target['lineID'],service)

    def test_complete_wrapped_names_do_not_steal_their_shorter_neighbours(self):
        def span(text,x,y):
            return dict(text=text,size=2.5,color=2301728,bbox=(x,y,x+15,y+3))
        build.SPANS = [span('New Cross',300,400),span('New Cross',400,400),
                       span('Gate',400,403),span('London',500,400),
                       span('Bridge',500,403),span('Lea Bridge',600,400),
                       span('New Cross',700,400)]
        build.configure_label_names(None,['New Cross','New Cross Gate','London Bridge','Lea Bridge'])
        cross = build.label_boxes(None,'New Cross')
        self.assertEqual([r.x0 for r in cross],[300,700])
        gate = build.label_boxes(None,'New Cross Gate')
        self.assertEqual(len(gate),1)
        self.assertEqual(gate[0].y1,406)
        self.assertEqual(build.label_boxes(None,'London Bridge')[0].x0,500)
        self.assertEqual(build.label_boxes(None,'Lea Bridge')[0].x0,600)


if __name__ == '__main__':
    unittest.main()
