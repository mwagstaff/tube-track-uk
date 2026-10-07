"""Validate station ownership against TfL labels and route order, not app IDs."""
import json
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import reference_alignment as alignment

ROOT = Path(__file__).resolve().parents[3]


class StationMarkerIdentityTests(unittest.TestCase):
    def test_all_native_markers_belong_to_their_printed_station(self):
        document = json.loads((ROOT/'TubeTrackUK/Resources/BeckMap/v1/full-underground.json').read_text())
        stations = json.loads((ROOT/'TubeTrackUK/Resources/TubeGraph.json').read_text())['stations']
        names = {s['id']:s['name'] for s in stations}
        reference = alignment.Reference(json.loads(alignment.REFERENCE_PATH.read_text()))
        pairs = alignment.pair_routes(alignment.Artwork(document),reference,names)
        count = 0
        for marker in document['stationMarkers']:
            for primitive in marker['primitives']:
                kind = primitive['kind']
                if kind not in {'circle','tick'}: continue
                count += 1
                symbol = primitive[kind]
                centre = tuple(symbol.get('centre',symbol.get('end')).values())
                services = [symbol['lineID']] if kind == 'tick' else marker['lineIDs']
                printed = []
                for service in services:
                    for source_kind,index in pairs.get((marker['stationID'],service),[]):
                        item = reference.ticks[index] if source_kind == 'tick' else reference.symbols[index]
                        printed.append((item['x'],item['y']))
                # The upper DLR platform circle joins the two lower Canning
                # Town circles; the shared label sits below the interchange.
                # Independently checked against the September source artwork.
                if marker['stationID'] == '940GZZDLCGT' and kind == 'circle':
                    printed.append((3287.992,1724.250))
                self.assertLessEqual(min((math.dist(centre,p) for p in printed),default=math.inf),25,
                                     (marker['stationID'],marker['name'],services,centre))
        self.assertEqual(count,639)


if __name__ == '__main__': unittest.main()
