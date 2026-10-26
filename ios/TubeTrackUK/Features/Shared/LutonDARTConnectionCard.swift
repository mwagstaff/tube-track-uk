import SwiftUI

struct LutonDARTConnectionCard: View {
    static let parkwayID = "nr:LTN"
    static let airportID = "nr:LUA"
    let atAirport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Luton DART", systemImage: "tram.fill")
                .font(.appHeadline()).accessibilityAddTraits(.isHeader)
            Text(atAirport ? "To Luton Airport Parkway" : "To Luton Airport terminal")
                .font(.appSubheadline(.semibold))
            Text("Around 4 minutes · frequent shuttle service")
                .font(.appSubheadline())
            Text(atAirport
                 ? "Follow signs for DART and trains to connect with National Rail at Parkway."
                 : "Follow signs for the DART connection to the airport terminal.")
                .font(.appSubheadline())
            Text("Connection information only. Live DART departures are unavailable here. Check the operator for current hours, frequency and tickets.")
                .font(.appCaption()).foregroundStyle(.secondary)
            Link(destination: URL(string: "https://www.lutondart.com/help/faqs/")!) {
                Label("Official DART service information", systemImage: "arrow.up.right.square")
                    .font(.appSubheadline(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityIdentifier("luton-dart-connection")
    }
}

struct LutonDARTAirportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LutonDARTConnectionCard(atAirport: true).padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Luton Airport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("DART · Parkway") {
    LutonDARTConnectionCard(atAirport: false).padding()
}

#Preview("DART · Airport · Large text") {
    LutonDARTAirportSheet()
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
