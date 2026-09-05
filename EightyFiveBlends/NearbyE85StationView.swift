import SwiftUI

struct NearbyE85StationView: View {
    @Environment(\.dismiss) private var dismiss
    let station: NearbyE85Station
    let snapshot: NearbyE85Snapshot
    @State private var directionsError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(station.name).font(.title2.bold())
                    Text(station.address).foregroundStyle(.secondary)
                    Text("Approximately \(station.distanceMiles, specifier: "%.1f") mi from your last app location")
                }
                Section("Reported E85 price") {
                    if let price = station.price {
                        Text(price.dollarsPerGallon, format: .currency(code: "USD")) + Text(" / US gallon")
                        Text(price.source == .saved ? "Saved by you" : "Community reported")
                        Text(price.status(at: .now))
                        if let date = price.reportedAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    } else {
                        Text("No price reported")
                    }
                    Text("Confirm price and availability at the pump.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Nearby snapshot") {
                    LabeledContent("Updated", value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let date = snapshot.locationAt {
                        LabeledContent("Location recorded", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("Distances are approximate straight-line distances. Return to Stations to refresh for your current location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Get directions", systemImage: "arrow.triangle.turn.up.right.diamond") {
                    directionsError = MapsRoutingHelper.openDirections(to: .init(
                        name: station.name, streetAddress: station.address, city: "", state: "", zip: "",
                        latitude: station.latitude, longitude: station.longitude))
                }
                if let directionsError { Text(directionsError).foregroundStyle(.secondary) }
            }
            .navigationTitle("Nearby E85")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
