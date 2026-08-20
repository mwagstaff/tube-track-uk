# Tube graph builder

`build_graph.py` combines current TfL station/line topology with an original
octilinear schematic layout. When passed `--osm-pbf`, it also routes every
station pair over Underground, DLR and Elizabeth line railway ways from
OpenStreetMap. API-only refreshes retain the reviewed OSM geometry already in
the output asset.

The OSM input should be generated from a reproducible regional `.osm.pbf`
snapshot with `osmium-tool`:

```sh
osmium tags-filter \
  --expressions=Tools/TubeGraphBuilder/osm-tube-filter.txt \
  --output-format=pbf \
  --output=tmp/tube-railways.osm.pbf \
  /path/to/great-britain.osm.pbf

/path/to/python-with-pyosmium \
  Tools/TubeGraphBuilder/build_graph.py \
  --osm-pbf tmp/tube-railways.osm.pbf
```

The app bundles only the resulting compact `TubeGraph.json`; preprocessing is
offline. OSM-derived builds retain `© OpenStreetMap contributors` and the ODbL
copyright link in the asset and app UI.
