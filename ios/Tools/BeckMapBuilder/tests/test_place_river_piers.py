import copy
import json
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import place_river_piers

IOS_ROOT = Path(__file__).resolve().parents[3]


class PlaceRiverPiersTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json").read_text())
        self.anchors = json.loads((IOS_ROOT / "TubeTrackUK/Resources/RiverSchematic.json").read_text())

    def test_bundled_piers_are_already_placed(self):
        self.assertEqual(place_river_piers.place(copy.deepcopy(self.anchors), self.document), self.anchors)

    def test_piers_sit_on_the_bank_edge_and_leave_room_for_walking_links(self):
        segments, edge = place_river_piers._segments(self.document)
        for anchor in self.anchors:
            centre = (anchor["x"] + anchor["offsetX"], anchor["y"] + anchor["offsetY"])
            distance = min(place_river_piers._distance_to_segment(centre, a, b) for a, b in segments)
            self.assertAlmostEqual(distance, edge, places=2, msg=anchor["id"])
            for station in anchor.get("walkingLinkStationIDs") or []:
                roundel = place_river_piers._roundel_near(self.document, station, centre)
                self.assertGreaterEqual(math.dist(centre, roundel), place_river_piers.MINIMUM_LINK_SPAN - 1e-3)

    def test_linked_pier_moves_to_its_station_bank(self):
        anchors = copy.deepcopy(self.anchors)
        london_eye = next(a for a in anchors if a["id"] == "930GWMP")
        london_eye["offsetY"] = -10.5  # wrongly on the north bank
        placed = next(a for a in place_river_piers.place(anchors, self.document) if a["id"] == "930GWMP")
        self.assertEqual(placed["offsetY"], 10.5)  # Waterloo is on the south bank


if __name__ == "__main__":
    unittest.main()
