//
//  StationLocationManager.swift
//  EightyFiveBlends
//

import CoreLocation

struct StationCoordinate: Equatable {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Observable
final class StationLocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus
    var latestCoordinate: StationCoordinate?
    /// Horizontal accuracy (meters) of the fix behind `latestCoordinate`. Negative or nil
    /// means the fix is unreliable. Pump-mode auto-triggering gates on this so a coarse
    /// indoor/cell fix can never place the user "at the pump" from half a mile away.
    var latestHorizontalAccuracyMeters: CLLocationAccuracy?

    var authorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var isAuthorizedForUserLocation: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Pump-mode auto-triggering needs a fix roughly as tight as its ~9 m entry radius
        // (see PumpProximity). Hundred-meter fixes made the old prompt fire from far away.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestUserLocation() {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            latestCoordinate = nil
        @unknown default:
            latestCoordinate = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            latestHorizontalAccuracyMeters = location.horizontalAccuracy
            latestCoordinate = StationCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .denied {
            authorizationStatus = manager.authorizationStatus
            latestCoordinate = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            latestCoordinate = nil
        default:
            break
        }
    }
}
