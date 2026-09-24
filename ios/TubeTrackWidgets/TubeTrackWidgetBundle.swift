import SwiftUI
import WidgetKit

@main
struct TubeTrackWidgetBundle: WidgetBundle {
    var body: some Widget {
        LineStatusWidget()
        StationDeparturesWidget()
        DepartureLiveActivity()
    }
}
