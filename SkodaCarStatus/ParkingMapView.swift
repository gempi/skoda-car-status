import MapKit
import SwiftUI

/// A small, non-interactive map with a marker at the parked car; clicking it opens Apple Maps.
struct ParkingMapView: View {
    let position: SkodaAPI.Position

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
    }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )), interactionModes: []) {
            Marker(VehicleModel.shared.vehicleName ?? "Car", systemImage: "car.fill", coordinate: coordinate)
        }
        .id(position)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: openInMaps)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func openInMaps() {
        let item = MKMapItem(location: CLLocation(latitude: position.latitude, longitude: position.longitude), address: nil)
        item.name = VehicleModel.shared.vehicleName ?? "Car"
        item.openInMaps()
    }
}
