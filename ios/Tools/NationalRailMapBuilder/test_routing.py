"""Regression tests for the shared, multiple-platform OSM router."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'TubeGraphBuilder'))
from route_national_rail_geography import RailwayGraph


class RoutingTests(unittest.TestCase):
    def test_cheapest_target_is_not_the_first_platform(self):
        nodes = [(0, 51), (.001, 51), (.0009, 51), (-.0009, 51), (-.001, 51)]
        edges = [dict(s=a, e=b, c=c, p=[nodes[a], nodes[b]])
                 for a,b,c in [(0,1,160),(0,2,180),(0,3,105),(3,4,15)]]
        graph = RailwayGraph(dict(nodes=nodes, edges=edges, stationAnchors={
            'AAA':[dict(n=0,d=0)], 'BBB':[dict(n=1,d=0),dict(n=4,d=0)],
        }))
        self.assertEqual(graph.route('AAA','BBB'), [nodes[0],nodes[3],nodes[4]])
        self.assertEqual(graph.route('BBB','AAA'), [nodes[4],nodes[3],nodes[0]])

    def test_missing_tracks_do_not_become_straight_lines(self):
        graph = RailwayGraph(dict(nodes=[(0,51),(1,51)],edges=[],stationAnchors={
            'AAA':[dict(n=0,d=0)], 'BBB':[dict(n=1,d=0)],
        }))
        self.assertIsNone(graph.route('AAA','BBB'))
        self.assertIsNone(graph.route('AAA','ZZZ'))


if __name__ == '__main__':
    unittest.main()
