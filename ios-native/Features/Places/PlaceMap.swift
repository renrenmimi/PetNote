import MapKit
import SwiftUI

/// Where a place is, on an Apple map.
///
/// Shown wherever the app shows an address that Apple Maps gave it, because
/// Apple's terms ask for the map with the address (Attachment 6, 2.4). Shown
/// for a place from the web too, when it has a position, since a map answers
/// "where" better than a line of text. Still, not something to pan: the
/// Directions link is the way into Maps.
struct PlaceMap: View {
    let details: PlaceDetails

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: details.latitude, longitude: details.longitude)
    }

    var body: some View {
        Map(
            initialPosition: .region(MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800
            )),
            interactionModes: []
        ) {
            Marker(details.name, coordinate: coordinate)
        }
        .frame(height: 180)
        .clipShape(.rect(cornerRadius: Radius.control))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Map of \(details.name)"))
        .accessibilityIdentifier("place.map")
    }
}
