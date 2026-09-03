//
//  TripNavigationLauncher.swift
//  EightyFiveBlends
//
//  fix/2.3.2-trip-planner-navigation — the single place Trip Planner decides how to hand a
//  route (or a single recommended fuel stop) off to an external navigation app. Every
//  Apple Maps / Google Maps / Waze button in TripPlannerView.swift calls into this file and
//  nothing else; no view there should build or open a maps URL itself.
//
//  ROOT CAUSE this file fixes: TripPlannerView previously built only HTTPS Google Maps/Waze
//  URLs (e.g. "https://www.google.com/maps/dir/?api=1&...") and opened them via SwiftUI's
//  `openURL` environment action, which resolves an HTTPS URL as a Universal Link. iOS does
//  not guarantee a Universal Link opens the installed app when triggered programmatically
//  from inside another app — in practice this reliably opened Safari/the in-app browser
//  instead of the installed Google Maps app, even with Google Maps installed. This is a
//  documented Google/Apple platform gotcha, not a defect in 85Blends' own route data.
//
//  THE FIX, per app:
//  - Google Maps: the existing, already-correct HTTPS Directions URL (built once below —
//    still the single source of truth for query-string construction: origin, destination,
//    and pipe-separated `waypoints` for recommended fuel stops) is wrapped using Google's own
//    documented `comgooglemapsurl://` scheme, which forces that identical URL into the
//    installed native app instead of a browser. Every query item (including `waypoints`) is
//    preserved byte-for-byte via `URLComponents` — only the scheme token changes — so this
//    can never drop a stop, reverse origin/destination, or mis-encode a coordinate.
//  - Waze: does not reliably support multi-stop routing from a URL handoff (a pre-existing,
//    documented limitation the UI already tells the user about) and has no
//    "wrap-the-web-URL" scheme like Google's — its native scheme has no host/path, just a
//    query — so the native `waze://` URL is rebuilt directly from the same destination
//    coordinate the web fallback uses, matching the shape already proven to work in
//    `MapsRoutingHelper.wazeURL(for:)` (AppPreferences.swift, a separate feature — see below).
//  - Apple Maps: was already using the correct native `MKMapItem`/`.openMaps(...)` API and
//    needed no URL-scheme fix — only centralizing into one call site here.
//
//  `LSApplicationQueriesSchemes` in Info.plist must declare `comgooglemaps`, `comgooglemapsurl`,
//  and `waze` for `canOpen(_:)` below to correctly detect installation. `comgooglemapsurl` was
//  missing before this fix (only `comgooglemaps`/`waze` were present) — without it,
//  `canOpenURL(_:)` on a `comgooglemapsurl://` URL always returns `false` regardless of
//  whether Google Maps is installed, silently defeating this exact fix.
//
//  Distinct from `MapsRoutingHelper` (AppPreferences.swift): that is a separate, existing,
//  unrelated single-destination "Get Directions to one station" launcher used elsewhere in
//  the app (Stations/Calculator), driven by the user's own Preferred Maps App setting, with
//  its own (different, and correct for its own use case) installed/not-installed fallback
//  policy. Trip Planner's routes carry an origin + destination + zero-or-more ordered
//  fuel-stop waypoints, which that helper does not model, and Trip Planner's UI always shows
//  all three app choices side by side rather than one preferred app — reusing that helper
//  here would either lose waypoint support or require reshaping an unrelated, already-working
//  feature. Not touched by this fix.
//

import Foundation
import MapKit
import CoreLocation
import UIKit

/// Abstracts `UIApplication`'s URL-opening so navigation-launch DECISIONS (native app found
/// vs. not) can be exercised in a unit test without ever touching a real installed app,
/// launching Safari, or running on a device. The shipping app always uses
/// `UIApplication.shared`; tests inject a fake that reports whatever installed/not-installed
/// state the test wants to exercise. Deliberately named `canOpen`/`launch` — NOT `canOpenURL`/
/// `open` — so this extension's methods can never collide with (and risk ambiguous-overload
/// call sites for) `UIApplication`'s own `canOpenURL(_:)`/`open(_:options:completionHandler:)`
/// anywhere else in the app.
protocol ExternalAppURLOpening {
    func canOpen(_ url: URL) -> Bool
    func launch(_ url: URL)
}

extension UIApplication: ExternalAppURLOpening {
    func canOpen(_ url: URL) -> Bool { canOpenURL(url) }
    func launch(_ url: URL) { open(url, options: [:], completionHandler: nil) }
}

/// Centralizes every external-navigation-app launch Trip Planner performs. See file header
/// for the bug this fixes and why it's a new, Trip-Planner-scoped type rather than a reuse of
/// `MapsRoutingHelper`.
@MainActor
enum TripNavigationLauncher {
    /// Swapped out by tests; the real app never changes this.
    static var urlOpener: ExternalAppURLOpening = UIApplication.shared

    /// What's being handed off. `.route` carries an origin, a destination, and zero-or-more
    /// ordered fuel-stop waypoints between them (the main "Open Route" handoff). `.singleStop`
    /// is a single coordinate — e.g. "get directions to just this recommended stop" from its
    /// own card. `name` is used only for Apple Maps' on-map pin label; Google Maps/Waze URLs
    /// never carried a name/label parameter before this fix and still don't, so this preserves
    /// their existing behavior exactly.
    enum Destination {
        case route(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, waypoints: [CLLocationCoordinate2D])
        case singleStop(CLLocationCoordinate2D, name: String)
    }

    // MARK: - Apple Maps
    // Already the correct native API (MKMapItem / .openMaps) before this fix — centralized
    // into one call site here, functional behavior otherwise unchanged.

    static func openAppleMaps(for destination: Destination) {
        switch destination {
        case .route(let origin, let dest, let waypoints):
            var items: [MKMapItem] = [namedMapItem(origin, name: "Start")]
            for (index, coordinate) in waypoints.enumerated() {
                let label = waypoints.count == 1 ? "Fuel Stop" : "Fuel Stop \(index + 1)"
                items.append(namedMapItem(coordinate, name: label))
            }
            items.append(namedMapItem(dest, name: "Destination"))
            MKMapItem.openMaps(
                with: items,
                launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
            )
        case .singleStop(let coordinate, let name):
            namedMapItem(coordinate, name: name.isEmpty ? "Station" : name)
                .openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        }
    }

    private static func namedMapItem(_ coordinate: CLLocationCoordinate2D, name: String) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    // MARK: - Google Maps

    /// The pre-existing, still-correct HTTPS Google Maps Directions URL — origin/destination/
    /// waypoints in Google's documented "Maps URLs" format (`waypoints=` pipe-separated for
    /// multiple stops). This is the single place that format is built; both the native URL
    /// below and the web fallback are derived from it, so there is exactly one query-string
    /// implementation to get right, not several. Pure and testable: same coordinates in,
    /// same URL out, every time.
    static func googleMapsWebURL(for destination: Destination) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        var queryItems = [URLQueryItem(name: "api", value: "1")]
        switch destination {
        case .route(let origin, let dest, let waypoints):
            queryItems.append(URLQueryItem(name: "origin", value: coordinateString(origin)))
            queryItems.append(URLQueryItem(name: "destination", value: coordinateString(dest)))
            if waypoints.isEmpty == false {
                let waypointValue = waypoints.map(coordinateString).joined(separator: "|")
                queryItems.append(URLQueryItem(name: "waypoints", value: waypointValue))
            }
        case .singleStop(let coordinate, _):
            queryItems.append(URLQueryItem(name: "destination", value: coordinateString(coordinate)))
        }
        queryItems.append(URLQueryItem(name: "travelmode", value: "driving"))
        components?.queryItems = queryItems
        return components?.url
    }

    /// Google's documented mechanism for forcing an existing, already-correct Google Maps web
    /// URL to open directly in the installed native app instead of a browser: replace the
    /// `https` scheme with `comgooglemapsurl` and change nothing else. Built via
    /// `URLComponents` from the web URL itself (never a blind string prefix) so every query
    /// item — including `waypoints` — is preserved exactly; this can never drop a stop,
    /// reverse origin/destination, or double-encode anything, because the query string is
    /// never touched at all.
    static func googleMapsNativeURL(for destination: Destination) -> URL? {
        guard let webURL = googleMapsWebURL(for: destination),
              var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "comgooglemapsurl"
        return components.url
    }

    static func openGoogleMaps(for destination: Destination) {
        guard let webURL = googleMapsWebURL(for: destination) else { return }
        openNativeThenFallback(native: googleMapsNativeURL(for: destination), webFallback: webURL)
    }

    // MARK: - Waze
    // Waze does not reliably support multi-stop routing from a URL handoff (a pre-existing,
    // documented limitation, not something this fix changes) — a `.route` destination always
    // opens the final destination only, exactly matching prior behavior; the UI separately
    // tells the user to add a recommended stop manually (see wazeHandoffHelperRow /
    // navigationWazeStatus in TripPlannerView.swift).

    static func wazeWebURL(for destination: Destination) -> URL? {
        var components = URLComponents(string: "https://waze.com/ul")
        components?.queryItems = wazeQueryItems(for: destination)
        return components?.url
    }

    /// Waze's native scheme has no host/path — just `waze://` plus a query — so (unlike
    /// Google) this is rebuilt directly rather than scheme-swapped from the web URL. Matches
    /// the `waze://` shape already used by the existing, working
    /// `MapsRoutingHelper.wazeURL(for:)` (AppPreferences.swift, a separate feature).
    static func wazeNativeURL(for destination: Destination) -> URL? {
        var components = URLComponents(string: "waze://")
        components?.queryItems = wazeQueryItems(for: destination)
        return components?.url
    }

    private static func wazeQueryItems(for destination: Destination) -> [URLQueryItem] {
        let coordinate: CLLocationCoordinate2D
        switch destination {
        case .route(_, let dest, _): coordinate = dest
        case .singleStop(let stop, _): coordinate = stop
        }
        return [
            URLQueryItem(name: "ll", value: coordinateString(coordinate)),
            URLQueryItem(name: "navigate", value: "yes")
        ]
    }

    static func openWaze(for destination: Destination) {
        guard let webURL = wazeWebURL(for: destination) else { return }
        openNativeThenFallback(native: wazeNativeURL(for: destination), webFallback: webURL)
    }

    // MARK: - Shared open logic

    /// Tries the native app URL first, and only if the corresponding app is actually
    /// installed (`canOpen(_:)` — this is what `LSApplicationQueriesSchemes` in Info.plist
    /// must declare the scheme for); falls back to the HTTPS web URL otherwise. The web
    /// fallback always succeeds as an action (it either opens the app via Universal Link if
    /// iOS chooses to, or opens in the browser) — this is the "no dead button, no crash, no
    /// silent failure when the app isn't installed" requirement.
    private static func openNativeThenFallback(native: URL?, webFallback: URL) {
        if let native, urlOpener.canOpen(native) {
            urlOpener.launch(native)
        } else {
            urlOpener.launch(webFallback)
        }
    }

    private static func coordinateString(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }
}
