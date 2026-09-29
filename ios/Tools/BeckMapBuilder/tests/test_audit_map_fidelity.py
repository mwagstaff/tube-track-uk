import copy
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "audit_map_fidelity.py"
IOS_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(SCRIPT_PATH.parent))
import audit_map_fidelity as audit_module
import normalize_official_geometry as official_geometry_module
import normalize_station_markers as normalize_module


def marker(station_id, name, primitives, anchor=(10, 10), line_ids=("central",)):
    return {
        "stationID": station_id,
        "name": name,
        "lineIDs": list(line_ids),
        "anchor": {"x": anchor[0], "y": anchor[1]},
        "hitRadius": 24,
        "primitives": primitives,
    }


def circle(x, y):
    return {
        "kind": "circle",
        "circle": {"centre": {"x": x, "y": y}, "radius": 8.5, "outlineWidth": 3.5},
    }


def connector(start, end):
    return {
        "kind": "connector",
        "connector": {
            "start": {"x": start[0], "y": start[1]},
            "end": {"x": end[0], "y": end[1]},
            "width": 7.5,
        },
    }


def tick(start, end):
    return {
        "kind": "tick",
        "tick": {
            "lineID": "central",
            "start": {"x": start[0], "y": start[1]},
            "end": {"x": end[0], "y": end[1]},
            "width": 3.2,
        },
    }


class MapFidelityAuditTests(unittest.TestCase):
    def manifest(self):
        return {
            "reference": {
                "title": "Fixture",
                "printedRevision": "test",
                "pdf": {"path": "missing.pdf", "sha256": "missing"},
                "raster": {"path": "missing.png", "sha256": "missing", "pixelSize": [50, 50]},
                "coordinateSystem": {"artworkUnitsPerReferencePixel": 2},
            },
            "supplementalSegmentIDs": [],
            "baselineStyles": {
                "document": {
                    "routeStrokeWidth": 8.3,
                    "affectedOuterStrokeWidth": 19,
                    "affectedKnockoutStrokeWidth": 15,
                    "affectedRouteStrokeWidth": 10,
                    "primaryLabelFontSize": 18,
                    "secondaryLabelFontSize": 16,
                    "labelPadding": 2,
                },
                "roundel": {"radius": 8.5, "outlineWidth": 3.5},
                "tick": {"length": 14, "width": 3.2},
            },
            "thresholds": {
                "axisAngleMediumDegrees": 0.25,
                "axisAngleHighDegrees": 1,
                "straightSegmentMinimumLength": 12,
                "connectorEndpointMediumDistanceArtworkUnits": 0.01,
                "connectorEndpointHighDistanceArtworkUnits": 8.5,
                "roundelPortMediumDistanceArtworkUnits": 1,
                "roundelPortHighDistanceArtworkUnits": 8.5,
                "tickPortDistanceArtworkUnits": 1,
                "tickPerpendicularDegrees": 0.5,
                "styleTolerance": 0.01,
            },
            "colourAuditStatus": "pending",
        }

    def document(self, markers, path_end=(20, 10)):
        return {
            "identifier": "fixture",
            "schemaVersion": {"major": 1, "minor": 2},
            "artworkSize": {"width": 100, "height": 100},
            "styles": self.manifest()["baselineStyles"]["document"],
            "paths": [{
                "id": "path",
                "commands": [
                    {"op": "move", "to": {"x": 10, "y": 10}},
                    {"op": "line", "to": {"x": path_end[0], "y": path_end[1]}},
                ],
            }],
            "segments": [{
                "id": "central:a:b",
                "lineID": "central",
                "fromStationID": "a",
                "toStationID": "b",
                "fromPort": {"x": 10, "y": 10},
                "toPort": {"x": path_end[0], "y": path_end[1]},
                "pathID": "path",
                "pathDirection": "forward",
                "translation": {"x": 0, "y": 0},
            }],
            "stationMarkers": markers,
            "labels": [],
            "routes": [],
            "supportedLineIDs": ["central"],
        }

    def graph(self):
        return {
            "stations": [{"id": "a"}, {"id": "b"}],
            "segments": [{"id": "central:a:b"}],
        }

    def through_document(self, markers):
        """A horizontal line a (10, 10) - m (20, 10) - b (30, 10)."""
        document = self.document(markers)
        document["paths"] = [
            {"id": "path-am", "commands": [
                {"op": "move", "to": {"x": 10, "y": 10}}, {"op": "line", "to": {"x": 20, "y": 10}},
            ]},
            {"id": "path-mb", "commands": [
                {"op": "move", "to": {"x": 20, "y": 10}}, {"op": "line", "to": {"x": 30, "y": 10}},
            ]},
        ]
        document["segments"] = [
            {
                "id": f"central:{a}:{b}", "lineID": "central",
                "fromStationID": a, "toStationID": b,
                "fromPort": {"x": start, "y": 10}, "toPort": {"x": start + 10, "y": 10},
                "pathID": path_id, "pathDirection": "forward", "translation": {"x": 0, "y": 0},
            }
            for a, b, start, path_id in (("a", "m", 10, "path-am"), ("m", "b", 20, "path-mb"))
        ]
        return document

    def through_graph(self):
        return {
            "stations": [{"id": "a"}, {"id": "m"}, {"id": "b"}],
            "segments": [{"id": "central:a:m"}, {"id": "central:m:b"}],
        }

    def test_canonical_connector_is_not_flagged(self):
        markers = [
            marker("a", "A", [circle(10, 10), connector((10, 10), (20, 20)), circle(20, 20)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_connectors()
        self.assertNotIn("connector-angle-review", {finding.code for finding in audit.findings})

    def test_noncanonical_connector_is_high_with_station_id(self):
        markers = [
            marker("a", "A", [circle(10, 10), connector((10, 10), (20, 15)), circle(20, 15)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_connectors()
        finding = next(finding for finding in audit.findings if finding.code == "connector-angle-review")
        self.assertEqual(finding.severity, "high")
        self.assertEqual(finding.evidence["stationID"], "a")

    def test_perpendicular_tick_passes_and_skewed_tick_fails(self):
        # Termini carry a bar centred across the line end; the through station
        # a one-sided tick from the line centre.
        termini = [
            marker("a", "A", [tick((10, -4), (10, 24))]),
            marker("b", "B", [tick((30, -4), (30, 24))], anchor=(30, 10)),
        ]
        passing = termini + [marker("m", "M", [tick((20, 10), (20, -4))], anchor=(20, 10))]
        audit = audit_module.MapFidelityAudit(
            self.through_document(passing), self.through_graph(), self.manifest()
        )
        audit.audit_ticks()
        codes = {finding.code for finding in audit.findings}
        self.assertNotIn("tick-not-perpendicular", codes)
        self.assertNotIn("tick-not-on-route-port", codes)

        failing = termini + [marker("m", "M", [tick((20, 10), (34, 10))], anchor=(20, 10))]
        audit = audit_module.MapFidelityAudit(
            self.through_document(failing), self.through_graph(), self.manifest()
        )
        audit.audit_ticks()
        finding = next(finding for finding in audit.findings if finding.code == "tick-not-perpendicular")
        self.assertEqual(finding.evidence["stationID"], "m")

    def test_route_angle_candidate_is_grouped_by_line(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(30, 20)], anchor=(30, 20)),
        ]
        audit = audit_module.MapFidelityAudit(
            self.document(markers, path_end=(30, 20)), self.graph(), self.manifest()
        )
        audit.audit_routes()
        finding = next(finding for finding in audit.findings if finding.code == "non-canonical-straight-runs")
        self.assertEqual(finding.location, "central")
        self.assertEqual(finding.severity, "medium")
        self.assertEqual(finding.evidence["count"], 1)

    def test_roundel_on_connector_endpoint_is_attached(self):
        markers = [
            marker("a", "A", [connector((10, 10), (16, 18)), circle(16, 18)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        self.assertNotIn("roundel-not-on-route-port", {finding.code for finding in audit.findings})

    def test_tick_on_middle_of_adjacent_path_fails_station_endpoint_check(self):
        markers = [
            marker("a", "A", [tick((15, 3), (15, 17))], anchor=(15, 10)),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_ticks()
        codes = {finding.code for finding in audit.findings}
        self.assertIn("tick-not-on-route-port", codes)

    def test_roundel_spanning_an_offset_lane_is_attached(self):
        # TfL roundels sit over parallel lanes, so a port inside the ring counts.
        markers = [
            marker("a", "A", [circle(10, 14)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        self.assertNotIn("roundel-not-on-route-port", {finding.code for finding in audit.findings})

    def test_roundel_beside_its_port_is_high(self):
        markers = [
            marker("a", "A", [circle(10, 22)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        finding = next(finding for finding in audit.findings if finding.code == "roundel-not-on-route-port")
        self.assertEqual(finding.severity, "high")

    def test_roundel_near_a_connector_end_is_medium(self):
        markers = [
            marker("a", "A", [circle(10, 10), connector((10, 10), (10, 40))]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
            marker("c", "C", [circle(12, 40)], anchor=(12, 40)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        finding = next(
            finding for finding in audit.findings
            if finding.code == "roundel-not-on-route-port" and finding.evidence["stationID"] == "c"
        )
        self.assertEqual(finding.severity, "medium")

    def test_markdown_output_is_deterministic(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        manifest = self.manifest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "missing.pdf").write_bytes(b"fixture")
            # Minimal valid PNG header with a 50 x 50 IHDR width/height.
            (root / "missing.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 50, 50))
            manifest["reference"]["pdf"]["sha256"] = audit_module.sha256(root / "missing.pdf")
            manifest["reference"]["raster"]["sha256"] = audit_module.sha256(root / "missing.png")
            audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), manifest)
            report = audit.run(root / "manifest.json")
            self.assertEqual(audit_module.markdown_report(report), audit_module.markdown_report(report))

    def test_reference_hash_drift_is_critical(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        manifest = self.manifest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "missing.pdf").write_bytes(b"unexpected")
            (root / "missing.png").write_bytes(
                b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 50, 50)
            )
            audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), manifest)
            report = audit.run(root / "manifest.json")
            codes = {finding["code"] for finding in report["findings"]}
            self.assertIn("reference-hash-mismatch", codes)

    def test_connector_endpoint_promotes_matching_tick_to_roundel(self):
        markers = [
            marker("a", "A", [tick((10, 3), (10, 17))]),
            marker(
                "b", "B",
                [connector((10, 10), (20, 10)), circle(20, 10)],
                anchor=(20, 10),
            ),
        ]
        document = self.document(markers)
        self.assertEqual(normalize_module._promote_connector_endpoint_ticks(document), 1)
        kinds = [primitive["kind"] for primitive in document["stationMarkers"][0]["primitives"]]
        self.assertEqual(kinds, ["circle"])

    def test_skewed_terminus_bar_is_regenerated_from_local_path_tangent(self):
        markers = [
            marker("a", "A", [tick((3, 10), (17, 10))]),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        document = self.document(markers)
        self.assertEqual(normalize_module._normalize_tick_angles(document), 1)
        corrected = document["stationMarkers"][0]["primitives"][0]["tick"]
        self.assertEqual(corrected["start"]["x"], 10)
        self.assertEqual(corrected["end"]["x"], 10)
        self.assertAlmostEqual(
            abs(corrected["end"]["y"] - corrected["start"]["y"]),
            2 * normalize_module.TICK_HALF_LENGTH,
            places=3,
        )

    def test_skewed_through_tick_is_regenerated_on_its_side(self):
        markers = [
            marker("a", "A", [tick((10, 0.23), (10, 19.77))]),
            marker("m", "M", [tick((20, 10), (27, 3))], anchor=(20, 10)),
            marker("b", "B", [tick((30, 0.23), (30, 19.77))], anchor=(30, 10)),
        ]
        document = self.through_document(markers)
        self.assertEqual(normalize_module._normalize_tick_angles(document), 1)
        corrected = document["stationMarkers"][1]["primitives"][0]["tick"]
        self.assertEqual(corrected["start"], {"x": 20, "y": 10})
        self.assertEqual(corrected["end"], {
            "x": 20, "y": round(10 - normalize_module.TICK_HALF_LENGTH, 3)
        })

    def test_bundled_map_has_no_critical_fidelity_findings(self):
        document = audit_module.load_json(
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        )
        graph = audit_module.load_json(IOS_ROOT / "TubeTrackUK/Resources/TubeGraph.json")
        manifest_path = IOS_ROOT / "design_brief/beck_map/tfl-standard-map-april-2026.json"
        manifest = audit_module.load_json(manifest_path)
        report = audit_module.MapFidelityAudit(document, graph, manifest).run(manifest_path)
        self.assertNotIn("critical", report["summary"]["bySeverity"])
        self.assertFalse(any(
            finding["evidence"].get("stationID") == "940GZZLUHSC"
            for finding in report["findings"]
        ))

    def test_bundled_western_geometry_matches_source_verified_relationships(self):
        document = audit_module.load_json(
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        )
        markers = {
            marker["stationID"]: marker for marker in document["stationMarkers"]
        }

        def connector(station_id):
            return next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )

        for station_id in ("910GKENOLYM", "910GWBRMPTN"):
            primitive = connector(station_id)
            payload = primitive[primitive["kind"]]
            self.assertAlmostEqual(
                payload["start"]["y"], payload["end"]["y"], places=3
            )

        # TfL links the two Hammersmith stations with a walking interchange.
        hammersmith = markers["940GZZLUHSC"]
        self.assertEqual(
            [primitive["kind"] for primitive in hammersmith["primitives"]],
            ["walkingConnector", "circle"],
        )
        self.assertEqual(
            set(hammersmith["lineIDs"]), {"circle", "hammersmith-city"}
        )
        walk = hammersmith["primitives"][0]["walkingConnector"]
        self.assertEqual(walk["start"], hammersmith["anchor"])
        self.assertEqual(walk["end"], markers["940GZZLUHSD"]["anchor"])

        shepherds_bush = connector("910GSHPDSB")
        self.assertEqual(shepherds_bush["kind"], "walkingConnector")
        payload = shepherds_bush["walkingConnector"]
        dx = payload["end"]["x"] - payload["start"]["x"]
        dy = payload["end"]["y"] - payload["start"]["y"]
        self.assertAlmostEqual(abs(dx), abs(dy), places=3)

        def line_port(station_id, line_id):
            ports = []
            for segment in document["segments"]:
                if segment["lineID"] != line_id:
                    continue
                if segment["fromStationID"] == station_id:
                    ports.append(segment["fromPort"])
                if segment["toStationID"] == station_id:
                    ports.append(segment["toPort"])
            self.assertTrue(ports)
            return ports[0]

        # Through-station ticks run from the line centre towards the name.
        for station_id in ("940GZZLUSBM", "940GZZLUGHK"):
            ticks = {
                primitive["tick"]["lineID"]: primitive["tick"]
                for primitive in markers[station_id]["primitives"]
                if primitive["kind"] == "tick"
            }
            for line_id in ("circle", "hammersmith-city"):
                self.assertEqual(ticks[line_id]["start"], line_port(station_id, line_id))
                self.assertLess(ticks[line_id]["end"]["x"], ticks[line_id]["start"]["x"])

        # The two coloured halves of each western stop must share one
        # perpendicular across the diagonal route at high zoom.
        for station_id in ("940GZZLUWSP", "940GZZLULAD", "940GZZLULRD"):
            ticks = {
                primitive["tick"]["lineID"]: primitive["tick"]
                for primitive in markers[station_id]["primitives"]
                if primitive["kind"] == "tick"
            }
            self.assertEqual(set(ticks), {"circle", "hammersmith-city"})
            starts = {line_id: tick["start"] for line_id, tick in ticks.items()}
            # The lanes' TfL ticks sit within 0.1 units of one perpendicular.
            self.assertAlmostEqual(
                starts["circle"]["x"] - starts["hammersmith-city"]["x"],
                starts["circle"]["y"] - starts["hammersmith-city"]["y"],
                delta=0.15,
            )
            for line_id, start in starts.items():
                self.assertEqual(start, line_port(station_id, line_id))

    def test_canada_water_has_one_physical_roundel_on_both_routes(self):
        document = json.loads((IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json").read_text())
        ids = {"940GZZLUCWR", "910GCNDAW"}
        markers = [m for m in document["stationMarkers"] if m["stationID"] in ids]
        self.assertEqual(len(markers), 2)  # Both departure feeds remain selectable.
        centre = markers[0]["anchor"]
        for marker in markers:
            self.assertEqual(marker["anchor"], centre)
            self.assertEqual([p["kind"] for p in marker["primitives"]], ["circle"])
            self.assertEqual(marker["primitives"][0]["circle"]["centre"], centre)
        # The Jubilee and Windrush lines both pass under the one TfL roundel.
        radius = markers[0]["primitives"][0]["circle"]["radius"]
        for segment in document["segments"]:
            for port_key, station_key in (("fromPort", "fromStationID"), ("toPort", "toStationID")):
                if segment[station_key] in ids:
                    port = segment[port_key]
                    self.assertLess(
                        ((port["x"] - centre["x"]) ** 2 + (port["y"] - centre["y"]) ** 2) ** 0.5,
                        radius,
                    )
        label = next(l for l in document["labels"] if l["stationID"] == "940GZZLUCWR")
        self.assertIn("910GCNDAW", label["associatedStationIDs"])

    def test_kensington_and_kenton_markers_follow_shared_route_geometry(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        markers = {record["stationID"]: record for record in document["stationMarkers"]}
        labels = {record["stationID"]: record for record in document["labels"]}

        def port(station_id, line_id):
            points = [
                segment[key]
                for segment in document["segments"]
                if segment["lineID"] == line_id
                for key, endpoint in (("fromPort", "fromStationID"), ("toPort", "toStationID"))
                if segment[endpoint] == station_id
            ]
            self.assertTrue(points)
            self.assertTrue(all(point == points[0] for point in points))
            return points[0]

        high_street = markers["940GZZLUHSK"]
        ticks = {
            primitive["tick"]["lineID"]: primitive["tick"]
            for primitive in high_street["primitives"]
        }
        self.assertEqual(set(ticks), {"circle", "district"})
        for line_id, tick_record in ticks.items():
            self.assertEqual(tick_record["start"], port("940GZZLUHSK", line_id))
            self.assertEqual(tick_record["start"]["y"], tick_record["end"]["y"])
        self.assertAlmostEqual(
            ticks["circle"]["start"]["y"], ticks["district"]["start"]["y"], delta=0.05
        )

        for station_id, line_id in (
            ("940GZZLUSKT", "bakerloo"), ("910GSKENTON", "lioness")
        ):
            marker_record = markers[station_id]
            self.assertEqual(marker_record["anchor"], port(station_id, line_id))
            self.assertLess(port("940GZZLUNKP", "metropolitan")["y"], marker_record["anchor"]["y"])
        self.assertAlmostEqual(
            markers["940GZZLUSKT"]["anchor"]["y"],
            markers["910GSKENTON"]["anchor"]["y"],
            delta=0.05,
        )

        kenton = markers["940GZZLUKEN"]["anchor"]
        self.assertEqual(kenton, markers["910GKTON"]["anchor"])
        for station_id in ("940GZZLUKEN", "910GKTON", "940GZZLUNKP"):
            self.assertIn("circle", [p["kind"] for p in markers[station_id]["primitives"]])
        northwick = markers["940GZZLUNKP"]["anchor"]
        northwick_port = port("940GZZLUNKP", "metropolitan")
        self.assertAlmostEqual(northwick["x"], northwick_port["x"], delta=0.5)
        self.assertAlmostEqual(northwick["y"], northwick_port["y"], delta=0.5)
        # One dotted walking link joins the Northwick Park and Kenton roundels.
        links = [
            primitive["walkingConnector"]
            for station_id in ("940GZZLUNKP", "940GZZLUKEN", "910GKTON")
            for primitive in markers[station_id]["primitives"]
            if primitive["kind"] == "walkingConnector"
        ]
        self.assertEqual(len(links), 1)
        ends = sorted((links[0]["start"], links[0]["end"]), key=lambda p: p["x"])
        for end, anchor in zip(ends, (northwick, kenton)):
            self.assertAlmostEqual(end["x"], anchor["x"], delta=0.05)
            self.assertAlmostEqual(end["y"], anchor["y"], delta=0.05)
        self.assertAlmostEqual(
            abs(ends[1]["x"] - ends[0]["x"]),
            abs(ends[1]["y"] - ends[0]["y"]),
            places=3,
        )
        self.assertIn("910GKTON", labels["940GZZLUKEN"]["associatedStationIDs"])
        self.assertIn("910GSKENTON", labels["940GZZLUSKT"]["associatedStationIDs"])

    def test_bundled_official_geometry_normalization_is_idempotent(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        original = copy.deepcopy(document)
        self.assertEqual(official_geometry_module.apply(document), 0)
        self.assertEqual(document, original)

    def test_bundled_northwest_interchanges_follow_official_diagonal_grammar(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        markers = {
            marker["stationID"]: marker for marker in document["stationMarkers"]
        }

        # The Metropolitan runs through Willesden Green without stopping, so
        # TfL draws a plain Jubilee tick there, not an interchange.
        self.assertEqual(
            [(p["kind"], p["tick"]["lineID"]) for p in markers["940GZZLUWIG"]["primitives"]],
            [("tick", "jubilee")],
        )

        for station_id in (
            "940GZZLUWYP",
            "910GWHMDSTD",
            "940GZZLUFYR",
            "910GFNCHLYR",
        ):
            primitive = next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )
            payload = primitive[primitive["kind"]]
            dx = payload["end"]["x"] - payload["start"]["x"]
            dy = payload["end"]["y"] - payload["start"]["y"]
            self.assertAlmostEqual(abs(dx), abs(dy), places=3)

        for station_id in ("910GWHMDSTD", "910GFNCHLYR"):
            walking_link = next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )
            self.assertEqual(walking_link["kind"], "walkingConnector")

        walking_pairs = (
            ("940GZZLUWHP", "910GWHMDSTD"),
            ("940GZZLUFYR", "910GFNCHLYR"),
        )
        for underground_id, mildmay_id in walking_pairs:
            underground_circles = {
                (round(p["circle"]["centre"]["x"]), round(p["circle"]["centre"]["y"]))
                for p in markers[underground_id]["primitives"] if p["kind"] == "circle"
            }
            mildmay_anchor = markers[mildmay_id]["anchor"]
            anchor = (round(mildmay_anchor["x"]), round(mildmay_anchor["y"]))
            # Links join TfL symbol centres, squared to 45 degrees: the
            # Overground roundel and one of the Underground station's roundels.
            # West Hampstead also walks on to its Thameslink station.
            links = [
                {(round(p["walkingConnector"][end]["x"]), round(p["walkingConnector"][end]["y"]))
                 for end in ("start", "end")}
                for p in markers[mildmay_id]["primitives"] if p["kind"] == "walkingConnector"
            ]
            self.assertTrue(any(anchor in ends and ends & underground_circles for ends in links))
        self.assertAlmostEqual(
            markers["910GWHMDSTD"]["anchor"]["y"],
            markers["910GFNCHLYR"]["anchor"]["y"],
            delta=0.05,
        )

        protected_segments = {
            "jubilee:940GZZLUKBN:940GZZLUWHP",
            "jubilee:940GZZLUFYR:940GZZLUWHP",
            "jubilee:940GZZLUFYR:940GZZLUSWC",
            "jubilee:940GZZLUSJW:940GZZLUSWC",
        }
        for segment in document["segments"]:
            if segment["id"] not in protected_segments:
                continue
            dx = segment["toPort"]["x"] - segment["fromPort"]["x"]
            dy = segment["toPort"]["y"] - segment["fromPort"]["y"]
            self.assertLess(abs(abs(dx) - abs(dy)), 0.2)

    def test_bundled_marker_normalization_is_idempotent(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        graph = json.loads((IOS_ROOT / "TubeTrackUK/Resources/TubeGraph.json").read_text())
        original = copy.deepcopy(document)
        self.assertEqual(normalize_module.normalize(document, graph), 0)
        self.assertEqual(document, original)


if __name__ == "__main__":
    unittest.main()
