import CoreGraphics
import MapKit

// Pure geometry for the medium widget's map: keeps the framing centered on the user and the
// nearest useful stations without ever touching MKMapSnapshotter, so it's cheap to unit test.
nonisolated enum NearbyE85MapRegion {
    /// A single very-close station must not zoom the map down to only a few streets.
    static let minimumSpanMiles: Double = 3
    /// One distant outlier must not zoom the map out across the entire metro area.
    static let maximumSpanMiles: Double = 20
    /// Leaves visible margin around the outermost pin instead of pinning it to the frame edge.
    static let paddingFactor: Double = 1.5
    private static let milesPerDegreeLatitude: Double = 69.0

    /// - Parameters:
    ///   - userCoordinate: The user's cached/recorded location.
    ///   - stationCoordinates: The stations to keep in frame (already capped/selected upstream).
    ///   - aspectRatio: width / height of the map area the region will be rendered into.
    static func region(userCoordinate: CLLocationCoordinate2D,
                        stationCoordinates: [CLLocationCoordinate2D],
                        aspectRatio: Double) -> MKCoordinateRegion {
        var minLatitude = userCoordinate.latitude, maxLatitude = userCoordinate.latitude
        var minLongitude = userCoordinate.longitude, maxLongitude = userCoordinate.longitude
        for coordinate in stationCoordinates {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                             longitude: (minLongitude + maxLongitude) / 2)
        // 1 degree of longitude shrinks toward the poles; this keeps span clamping in true miles.
        let milesPerDegreeLongitude = max(milesPerDegreeLatitude * cos(center.latitude * .pi / 180), 1)

        var latitudeSpanMiles = (maxLatitude - minLatitude) * milesPerDegreeLatitude * paddingFactor
        var longitudeSpanMiles = (maxLongitude - minLongitude) * milesPerDegreeLongitude * paddingFactor
        latitudeSpanMiles = min(max(latitudeSpanMiles, minimumSpanMiles), maximumSpanMiles)
        longitudeSpanMiles = min(max(longitudeSpanMiles, minimumSpanMiles), maximumSpanMiles)

        // Grow (never shrink) the shorter axis so the map fills the widget's frame without
        // distorting the projection.
        let aspectRatio = max(aspectRatio, 0.1)
        if longitudeSpanMiles < latitudeSpanMiles * aspectRatio {
            longitudeSpanMiles = latitudeSpanMiles * aspectRatio
        } else {
            latitudeSpanMiles = longitudeSpanMiles / aspectRatio
        }

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpanMiles / milesPerDegreeLatitude,
                                    longitudeDelta: longitudeSpanMiles / milesPerDegreeLongitude))
    }

    /// The user's own point often lands almost exactly on the nearest station's pin (e.g. the
    /// person is standing at the pump), which would otherwise hide the blue location marker
    /// entirely underneath the larger green pin. Nudges the point outward, away from the
    /// nearest occupied point, just enough to keep both markers visibly distinct.
    static func declutteredUserPoint(_ point: CGPoint, avoiding occupiedPoints: [CGPoint],
                                      minimumSeparation: CGFloat = 20) -> CGPoint {
        guard let nearest = occupiedPoints.min(by: {
            distance($0, point) < distance($1, point)
        }) else { return point }
        let delta = distance(nearest, point)
        guard delta < minimumSeparation else { return point }
        guard delta > 0.5 else {
            return CGPoint(x: point.x - minimumSeparation, y: point.y - minimumSeparation)
        }
        let scale = minimumSeparation / delta
        return CGPoint(x: nearest.x + (point.x - nearest.x) * scale,
                        y: nearest.y + (point.y - nearest.y) * scale)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
