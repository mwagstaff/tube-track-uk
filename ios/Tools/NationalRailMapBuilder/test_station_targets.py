import copy
import json
import math
import unittest
from pathlib import Path

from station_targets import bind_reviewed_targets, extract_ticks, reviewed_targets
from roundel_targets import OPERATOR_CODES

ROOT = Path(__file__).resolve().parents[2]


class StationTargetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads((ROOT/'TubeTrackUK/Resources/BeckMap/v1/london-rail-and-tube.json').read_text())
        cls.artwork = cls.document['referenceArtwork']
        cls.stations = [s for name in ['TubeGraph', 'NationalRailMap']
                        for s in json.loads((ROOT/f'TubeTrackUK/Resources/{name}.json').read_text())['stations']]
        cls.colors = {}
        for tick in cls.artwork['stationTicks']:
            service = tick.get('lineID') or next(s for s,code in OPERATOR_CODES.items()
                                                if tick['operatorID'] == 'national-rail:'+code)
            cls.colors[service] = cls.artwork['shapes'][tick['sourceShapeIndex']]['fill']

    def test_all_printed_station_symbols_match_independent_review(self):
        expected = reviewed_targets()
        self.assertEqual(len(expected),944)
        actual = [('circle',t) for t in self.artwork['stationRoundels']]+[('tick',t) for t in self.artwork['stationTicks']]
        self.assertEqual(len(actual),len(expected))
        for kind,target in actual:
            rows = [row for row in expected if row['kind'] == kind and math.dist(
                (float(row['x']),float(row['y'])),tuple(target['centre'].values())) < .02]
            self.assertEqual(len(rows),1)
            self.assertEqual((target['stationID'],target.get('lineID',''),target.get('operatorID','')),
                             (rows[0]['stationID'],rows[0]['lineID'],rows[0]['operatorID']))

    def test_all_source_ticks_have_a_target_and_rebuild_is_stable(self):
        ticks = extract_ticks(self.artwork['shapes'],self.artwork['stationRoundels'],self.colors)
        self.assertEqual(len(ticks),570)
        self.assertEqual({t['sourceShapeIndex'] for t in ticks},
                         {t['sourceShapeIndex'] for t in self.artwork['stationTicks']})
        rebuilt = copy.deepcopy(self.document)
        bind_reviewed_targets(rebuilt,self.stations,self.colors)
        self.assertEqual(rebuilt,self.document)

    def test_wrong_assignments_cannot_silently_rebuild(self):
        document = copy.deepcopy(self.document)
        document['referenceArtwork']['stationRoundels'][0]['stationID'] = '940GZZDLLIM'
        with self.assertRaisesRegex(ValueError,'Roundel assignment changed'):
            bind_reviewed_targets(document,self.stations,self.colors)

    def test_new_source_symbols_require_review(self):
        document = copy.deepcopy(self.document)
        tick = document['referenceArtwork']['shapes'][self.artwork['stationTicks'][0]['sourceShapeIndex']]
        extra = copy.deepcopy(tick)
        for command in extra['commands']:
            if 'to' in command: command['to']['x'] += 100
        document['referenceArtwork']['shapes'].append(extra)
        with self.assertRaisesRegex(ValueError,'Unreviewed or ambiguous tick'):
            bind_reviewed_targets(document,self.stations,self.colors)


if __name__ == '__main__': unittest.main()
