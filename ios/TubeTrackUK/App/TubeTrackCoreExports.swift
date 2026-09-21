// The shared models, API client and departure logic live in the TubeTrackCore
// package so the widget extension can use them. Re-exporting keeps every app
// file (and `@testable import TubeTrackUK` in tests) seeing those types as
// before the split.
@_exported import TubeTrackCore
