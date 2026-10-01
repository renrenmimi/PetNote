import MapKit
import SwiftUI

/// The places a list shows, on an Apple map, each a marker that opens it.
///
/// A list names places from Apple Maps in Apple's words, and Apple's terms
/// ask that its map go with what it says (Attachment 6, 2.4); a place's own
/// page has one already (`PlaceMap`). Places from the web are on it too, by
/// the position each stores. A screen of its own, opened from the list: as a
/// header it left a row or two of the list on the screen.
struct PlacesMap: View {
    /// A place with a position to show it at.
    struct Pin: Identifiable, Equatable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    let pins: [Pin]
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: String?

    var body: some View {
        Group {
            if pins.isEmpty {
                Text("None of these places has a position to show.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(Layout.pageInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("places.map.empty")
            } else {
                Map(position: $position, selection: $selected) {
                    ForEach(pins) { pin in
                        Marker(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude))
                            .tag(pin.id)
                    }
                }
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    selected = nil
                    onOpen(id)
                }
                .accessibilityLabel(Self.label(count: pins.count))
                .accessibilityIdentifier("places.map")
            }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("places.map.done")
            }
        }
    }

    /// The places of `places` that have a position: what each stores, for a
    /// place from the web; what Apple said, for one from Apple Maps, once it
    /// has answered.
    static func pins(for places: [Place], lookups: PlaceLookups) -> [Pin] {
        places.compactMap { place in
            guard case .found(let details) = lookups.shown(place), details.directionsURL != nil else { return nil }
            return Pin(id: place.id, name: lookups.name(of: place), latitude: details.latitude, longitude: details.longitude)
        }
    }

    static func label(count: Int) -> String {
        count == 1 ? String(localized: "Map of 1 place") : String(localized: "Map of \(count) places")
    }
}
