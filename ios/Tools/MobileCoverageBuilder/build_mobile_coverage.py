#!/usr/bin/env python3
"""Build the bundled August 2026 TfL mobile-coverage snapshot.

The source map distinguishes live tunnel sections (lime route casing) from
covered stations (blue station labels). Keeping the editorial ranges here and
emitting graph segment IDs makes changes reviewable while ensuring the runtime
resource cannot drift away from TubeGraph.json.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


IOS_ROOT = Path(__file__).resolve().parents[2]
GRAPH_PATH = IOS_ROOT / "TubeTrackUK" / "Resources" / "TubeGraph.json"
OUTPUT_PATH = (
    IOS_ROOT
    / "TubeTrackUK"
    / "Resources"
    / "MobileCoverage"
    / "v1"
    / "mobile-coverage-august-2026.json"
)

SOURCE_URL = "https://content.tfl.gov.uk/tube-map-below-ground-4g-and-5g-coverage.pdf"


# Sections treated as below ground when the user selects the underground-only
# view. Portal-adjacent segments are deliberately included so the display does
# not imply uninterrupted ordinary street coverage through tunnel entrances.
BELOW_GROUND_RANGES = [
    ("bakerloo", "Elephant & Castle", "Queen's Park", None),
    ("central", "White City", "Leytonstone", 0),
    ("central", "Leytonstone", "Newbury Park", 1),
    ("circle", "Royal Oak", "Aldgate", None),
    ("circle", "Aldgate", "Paddington", None),
    ("circle", "Paddington", "Edgware Road (Circle Line)", None),
    ("district", "Earl's Court", "Bow Road", 0),
    ("district", "Earl's Court", "Edgware Road (Circle Line)", 1),
    ("hammersmith-city", "Royal Oak", "Bow Road", None),
    ("jubilee", "Finchley Road", "Canning Town", None),
    ("metropolitan", "Finchley Road", "Aldgate", 1),
    ("northern", "Battersea Power Station", "Hampstead", 0),
    ("northern", "Battersea Power Station", "Highgate", 1),
    ("northern", "Morden", "Hampstead", 2),
    ("northern", "Morden", "Highgate", 3),
    ("piccadilly", "Earl's Court", "Arnos Grove", 0),
    ("piccadilly", "Hounslow West", "Heathrow Terminal 4", 0),
    ("piccadilly", "Hounslow West", "Heathrow Terminal 5", 1),
    ("victoria", "Brixton", "Walthamstow Central", None),
    ("waterloo-city", "Waterloo", "Bank", None),
    ("dlr", "Bank DLR Station", "Shadwell DLR Station", 0),
    ("dlr", "Island Gardens DLR Station", "Greenwich DLR Station", 0),
    ("dlr", "King George V DLR Station", "Woolwich Arsenal DLR Station", 1),
    ("elizabeth", "Paddington", "Abbey Wood", 0),
    ("elizabeth", "Whitechapel", "Stratford (London)", 7),
    ("elizabeth", "Heathrow Terminals 2 & 3", "Heathrow Terminal 4", 0),
    ("elizabeth", "Heathrow Terminals 2 & 3", "Heathrow Terminal 5", 1),
    ("windrush", "Highbury & Islington", "New Cross ELL", 0),
    ("windrush", "Highbury & Islington", "New Cross Gate", 1),
]


# Lime-cased paths on TfL's August 2026 publication. Shared track is listed for
# each service so both renderers can retain the correct line colour.
COVERED_TUNNEL_RANGES = [
    ("bakerloo", "Queen's Park", "Edgware Road (Bakerloo)", None),
    ("bakerloo", "Piccadilly Circus", "Embankment", None),
    ("central", "Shepherd's Bush (Central)", "St. Paul's", 0),
    ("circle", "Bayswater", "Paddington", None),
    ("circle", "Euston Square", "King's Cross St. Pancras", None),
    ("circle", "Barbican", "Moorgate", None),
    ("circle", "Sloane Square", "Victoria", None),
    ("circle", "Temple", "Monument", None),
    ("district", "Bayswater", "Paddington", 1),
    ("district", "Sloane Square", "Victoria", 0),
    ("district", "Cannon Street", "Monument", 0),
    ("hammersmith-city", "Euston Square", "King's Cross St. Pancras", None),
    ("hammersmith-city", "Barbican", "Moorgate", None),
    ("jubilee", "Finchley Road", "Canning Town", None),
    ("metropolitan", "Euston Square", "King's Cross St. Pancras", 1),
    ("metropolitan", "Barbican", "Moorgate", 1),
    ("northern", "Hampstead", "Camden Town", 0),
    ("northern", "Highgate", "Camden Town", 1),
    ("northern", "Camden Town", "Kennington", 1),
    ("northern", "Camden Town", "Bank", 3),
    ("northern", "Morden", "Kennington", 2),
    ("northern", "Battersea Power Station", "Kennington", 0),
    ("piccadilly", "Holloway Road", "Caledonian Road", 0),
    ("piccadilly", "King's Cross St. Pancras", "Gloucester Road", 0),
    ("victoria", "Brixton", "Euston", None),
    ("elizabeth", "Paddington", "Abbey Wood", 0),
    ("elizabeth", "Whitechapel", "Stratford (London)", 7),
]


# Lines explicitly represented in the PDF legend. Below-ground sections on
# other services remain "unknown" instead of being called unavailable.
VERIFIED_LINE_IDS = [
    "bakerloo",
    "central",
    "circle",
    "district",
    "hammersmith-city",
    "jubilee",
    "metropolitan",
    "northern",
    "piccadilly",
    "victoria",
    "elizabeth",
]


# Blue station labels in the source PDF. Names are resolved to all matching
# graph station records so shared hubs receive a single coherent marker state.
COVERED_STATION_NAMES = [
    "Abbey Wood",
    "Angel",
    "Archway",
    "Balham",
    "Bank",
    "Barbican",
    "Battersea Power Station",
    "Bayswater",
    "Belsize Park",
    "Bermondsey",
    "Blackfriars",
    "Bond Street",
    "Brixton",
    "Camden Town",
    "Canada Water",
    "Canning Town",
    "Cannon Street",
    "Chancery Lane",
    "Charing Cross",
    "Chalk Farm",
    "Clapham Common",
    "Clapham North",
    "Clapham South",
    "Colliers Wood",
    "Covent Garden",
    "Custom House",
    "Edgware Road (Bakerloo)",
    "Embankment",
    "Euston",
    "Euston Square",
    "Farringdon",
    "Finchley Road",
    "Gloucester Road",
    "Goodge Street",
    "Great Portland Street",
    "Green Park",
    "Hampstead",
    "Highgate",
    "Holland Park",
    "Holborn",
    "Holloway Road",
    "Hyde Park Corner",
    "Kennington",
    "Kentish Town",
    "Kilburn Park",
    "King's Cross St. Pancras",
    "Knightsbridge",
    "Lancaster Gate",
    "Leicester Square",
    "Liverpool Street",
    "London Bridge",
    "Maida Vale",
    "Mansion House",
    "Marble Arch",
    "Marylebone",
    "Monument",
    "Moorgate",
    "Morden",
    "Mornington Crescent",
    "Nine Elms",
    "North Greenwich",
    "Notting Hill Gate",
    "Old Street",
    "Oval",
    "Oxford Circus",
    "Paddington",
    "Paddington (H&C Line)-Underground",
    "Piccadilly Circus",
    "Pimlico",
    "Queen's Park",
    "Queensway",
    "Russell Square",
    "Shepherd's Bush (Central)",
    "Sloane Square",
    "South Wimbledon",
    "Southwark",
    "St. John's Wood",
    "St. Paul's",
    "Stockwell",
    "Stratford (London)",
    "Swiss Cottage",
    "Temple",
    "Tooting Bec",
    "Tooting Broadway",
    "Tottenham Court Road",
    "Tufnell Park",
    "Vauxhall",
    "Victoria",
    "Warren Street",
    "Warwick Avenue",
    "Waterloo",
    "Westminster",
    "Whitechapel",
    "Woolwich",
]


def build() -> dict:
    graph = json.loads(GRAPH_PATH.read_text())
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    lines_by_id = {line["id"]: line for line in graph["lines"]}
    segments_by_connection = {}
    for segment in graph["segments"]:
        key = (
            segment["lineID"],
            frozenset((segment["fromStationID"], segment["toStationID"])),
        )
        if key in segments_by_connection:
            raise ValueError(f"Ambiguous graph connection: {key}")
        segments_by_connection[key] = segment["id"]

    def segment_ids_for_range(record: tuple[str, str, str, int | None]) -> list[str]:
        line_id, from_name, to_name, route_index = record
        line = lines_by_id[line_id]
        candidates = (
            [(route_index, line["routes"][route_index])]
            if route_index is not None
            else list(enumerate(line["routes"]))
        )
        resolved = []
        for candidate_index, route in candidates:
            names = [stations_by_id[station]["name"] for station in route]
            if from_name not in names or to_name not in names:
                continue
            start_indices = [index for index, name in enumerate(names) if name == from_name]
            end_indices = [index for index, name in enumerate(names) if name == to_name]
            for start in start_indices:
                for end in end_indices:
                    lower, upper = sorted((start, end))
                    path = route[lower : upper + 1]
                    segment_ids = []
                    for first, second in zip(path, path[1:]):
                        key = (line_id, frozenset((first, second)))
                        try:
                            segment_ids.append(segments_by_connection[key])
                        except KeyError as error:
                            raise ValueError(
                                f"Missing {line_id} segment between "
                                f"{stations_by_id[first]['name']} and {stations_by_id[second]['name']}"
                            ) from error
                    resolved.append((candidate_index, segment_ids))
        if not resolved:
            raise ValueError(f"No {line_id} route contains {from_name!r} and {to_name!r}")
        shortest_length = min(len(item[1]) for item in resolved)
        shortest = [item for item in resolved if len(item[1]) == shortest_length]
        return shortest[0][1]

    def resolve_ranges(records: list[tuple[str, str, str, int | None]]) -> list[str]:
        return sorted({segment for record in records for segment in segment_ids_for_range(record)})

    station_ids_by_name = {}
    for station in graph["stations"]:
        station_ids_by_name.setdefault(station["name"], []).append(station["id"])

    missing_stations = sorted(set(COVERED_STATION_NAMES) - set(station_ids_by_name))
    if missing_stations:
        raise ValueError(f"Covered station names missing from graph: {missing_stations}")

    covered_segment_ids = resolve_ranges(COVERED_TUNNEL_RANGES)
    below_ground_segment_ids = resolve_ranges(BELOW_GROUND_RANGES)
    if not set(covered_segment_ids).issubset(below_ground_segment_ids):
        extra = sorted(set(covered_segment_ids) - set(below_ground_segment_ids))
        raise ValueError(f"Covered segments not classified below ground: {extra}")

    below_ground_station_ids = sorted(
        {
            endpoint
            for segment in graph["segments"]
            if segment["id"] in set(below_ground_segment_ids)
            for endpoint in (segment["fromStationID"], segment["toStationID"])
        }
    )
    covered_station_ids = sorted(
        {
            station_id
            for name in COVERED_STATION_NAMES
            for station_id in station_ids_by_name[name]
        }
    )

    return {
        "schemaVersion": 1,
        "identifier": "tfl-mobile-coverage-2026-08",
        "publishedAt": "2026-08-18",
        "sourceURL": SOURCE_URL,
        "graphGeneratedAt": graph["generatedAt"],
        "verifiedLineIDs": VERIFIED_LINE_IDS,
        "belowGroundSegmentIDs": below_ground_segment_ids,
        "coveredTunnelSegmentIDs": covered_segment_ids,
        "belowGroundStationIDs": below_ground_station_ids,
        "coveredStationIDs": covered_station_ids,
    }


def main() -> int:
    document = build()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(
        f"Wrote {OUTPUT_PATH}: "
        f"{len(document['coveredTunnelSegmentIDs'])} covered tunnels, "
        f"{len(document['coveredStationIDs'])} covered station records"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
