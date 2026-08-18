# TubeGraph Builder

`build_graph.py` downloads current London Underground route topology and station metadata from the Transport for London Unified API and compiles the deterministic runtime asset at `TubeTrackUK/Resources/TubeGraph.json`.

The generated graph contains the 11 Underground lines only. It stores shared station identifiers and line-specific segments with two coordinate representations:

- schematic points use a deterministic London projection and octilinear paths;
- geographic paths are sliced from TfL's official route `lineStrings`, anchored
  to TfL station coordinates. The builder records a station-to-station chord
  only as an explicit fallback when no route geometry can be associated safely.

Run from the repository root:

```sh
python3 Tools/TubeGraphBuilder/build_graph.py
```

The app never runs the builder or downloads topology at launch. Regenerate the asset deliberately when the network changes, review the diff and rerun the graph tests.
