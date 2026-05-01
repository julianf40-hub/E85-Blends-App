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

    var authorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var isAuthorizedForUserLocation: Bool {
        authorizationStatus == .authorizedWhenInUse
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
        if let coordinate = locations.last?.coordinate {
            latestCoordinate = StationCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
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
