"""Build shared direction data from TrainTrack's station catalogue.

Usage: python3 build_directions.py /path/to/train-track-uk
Coordinates support destination compass bearings without service-detail lookups.
"""
import json
import sys
from pathlib import Path

def build_directions(train_track, root):
    stations = json.loads((train_track / "api/train-track-api/resources/stations.json").read_text())
    coordinates = {}
    for station in stations:
        coordinates[station["crs"]] = [float(station["latitude"]), float(station["longitude"])]
    data = {"coordinatesByStation": dict(sorted(coordinates.items()))}
    content = json.dumps(data, separators=(",", ":")) + "\n"
    (root / "ios/TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailDirections.json").write_text(content)
    (root / "api/tube-track-api/data/national-rail-directions.json").write_text(content)
    print(f"Wrote direction coordinates for {len(coordinates)} railway stations")


if __name__ == "__main__":
    build_directions(Path(sys.argv[1]), Path(__file__).resolve().parents[3])
