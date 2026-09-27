import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_central_core_join as vector
import reference_alignment as alignment


def line(start, end):
    return vector.Curve("line", start, end)


class ReferenceAlignmentTests(unittest.TestCase):
    def test_overshoot_past_a_fork_is_removed(self):
        # Canning Town - Star Lane ran 27 units past the fork before turning back.
        curves = [line((0, 0), (100, 0)), line((100, 0), (80, 0)), line((80, 0), (60, -20))]
        cleaned = alignment._unhook(curves)
        points = [tuple(round(v, 6) for v in (*c.start, *c.end)) for c in cleaned]
        self.assertEqual(points, [(0, 0, 80, 0), (80, 0, 60, -20)])

    def test_hook_at_a_path_start_is_removed(self):
        # A path that first steps backwards and then runs through its own start.
        curves = [line((10, 10), (6, 6)), line((6, 6), (30, 30))]
        cleaned = alignment._unhook(curves)
        self.assertEqual(len(cleaned), 1)
        self.assertAlmostEqual(cleaned[0].start[0], 10, places=6)
        self.assertAlmostEqual(cleaned[0].start[1], 10, places=6)
        self.assertEqual(cleaned[0].end, (30, 30))

    def test_turn_without_a_back_step_is_kept(self):
        curves = [line((0, 0), (10, 0)), line((10, 0), (10, 10))]
        self.assertEqual(alignment._unhook(curves), curves)

    def test_near_diagonal_connector_is_squared_exactly(self):
        start, end = alignment._canonical((1086.461, 935.75), (1148.867, 873.336))
        rounded = [round(value, 3) for value in (*start, *end)]
        self.assertAlmostEqual(abs(rounded[2] - rounded[0]), abs(rounded[3] - rounded[1]), places=9)
        # The midpoint is kept.
        self.assertAlmostEqual((start[0] + end[0]) / 2, (1086.461 + 1148.867) / 2, places=3)

    def test_connector_far_from_an_axis_is_unchanged(self):
        self.assertEqual(alignment._canonical((0, 0), (10, 4)), ((0, 0), (10, 4)))

    def test_moving_a_junction_trims_a_branch_that_shares_the_moved_piece(self):
        # Two routes leave station s along the same line; moving s along that
        # line must trim both rather than hook one of them back.
        document = {
            "paths": [
                {"id": "p1", "commands": [{"op": "move", "to": {"x": 0, "y": 0}}, {"op": "line", "to": {"x": 40, "y": 0}}]},
                {"id": "p2", "commands": [{"op": "move", "to": {"x": 0, "y": 0}}, {"op": "line", "to": {"x": 50, "y": 0}}]},
                {"id": "p3", "commands": [{"op": "move", "to": {"x": 0, "y": 0}}, {"op": "line", "to": {"x": -30, "y": 0}}]},
            ],
            "segments": [
                {"id": f"x:s:{other}", "lineID": "x", "fromStationID": "s", "toStationID": other,
                 "fromPort": {"x": 0, "y": 0}, "toPort": {"x": end, "y": 0},
                 "pathID": path_id, "pathDirection": "forward", "translation": {"x": 0, "y": 0}}
                for other, end, path_id in (("a", 40, "p1"), ("b", 50, "p2"), ("c", -30, "p3"))
            ],
        }
        artwork = alignment.Artwork(document)
        self.assertTrue(artwork.move_junction("x", "s", (5, 0)))
        starts = {s["id"]: (s["fromPort"]["x"], s["fromPort"]["y"]) for s in document["segments"]}
        self.assertEqual(set(starts.values()), {(5, 0)})
        commands = {p["id"]: p["commands"] for p in document["paths"]}
        # The branches towards a and b start at the new port and run straight on.
        for path_id, end in (("p1", 40), ("p2", 50)):
            self.assertEqual([c["to"]["x"] for c in commands[path_id]], [5, end])
        # The branch towards c now carries the moved piece back to the fork.
        self.assertEqual([c["to"]["x"] for c in commands["p3"]], [5, 0, -30])

    def test_terminus_is_extended_to_the_disc_centre(self):
        curves = [line((0, 0), (20, 0))]
        extended = alignment._extended(curves, (25.5, 3))
        self.assertEqual(extended[-1].end, (25.5, 0))
        self.assertEqual(alignment._extended(curves, (18, 3)), curves)


if __name__ == "__main__":
    unittest.main()
