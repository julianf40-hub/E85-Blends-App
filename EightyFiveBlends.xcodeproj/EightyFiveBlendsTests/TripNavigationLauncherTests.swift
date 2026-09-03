//
//  TripNavigationLauncherTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for fix/2.3.2-trip-planner-navigation — the bug where tapping Google
//  Maps in Trip Planner opened Safari instead of the installed Google Maps app. These tests
//  exercise TripNavigationLauncher's pure URL-building and native-vs-fallback DECISION logic
//  directly, via an injected fake `ExternalAppURLOpening`, so they never touch a real
//  installed app, launch Safari, or require a device/Simulator to run.
//
//  Per CLAUDE.md, this repository has no wired test target yet (`xcodebuild test` will not
//  run these until one is added) — this file follows the same on-disk convention as the
//  existing PlanRequestTrackerTests.swift/StationsRecentSearchStoreCrossLaunchTests.swift/
//  SubscriptionManagerTests.swift, all likewise present but not yet part of a test target.
//

import Testing
import CoreLocation
@testable import EightyFiveBlends

/// Records every URL the launcher asks it to open/check, and lets a test control whether a
/// given native scheme reports as "installed" and whether launching it actually succeeds —
/// these are the two independent seams that make "Google Maps installed" vs. "not installed"
/// vs. "installed but the open call itself fails" all testable without a real device.
@MainActor
private final class FakeURLOpener: ExternalAppURLOpening {
    /// Schemes this fake reports as installed (i.e. `canOpen` returns true only for a URL
    /// whose scheme is in this set) — set per test to simulate installed/not-installed.
    var installedSchemes: Set<String> = []
    /// Schemes whose `launch` call should report failure even though `canOpen` reported them
    /// installed — simulates a native app that's installed but the open call still doesn't
    /// succeed (e.g. a stale LaunchServices registration). Defaults to empty, so existing
    /// tests that don't care about this keep their original "launch always succeeds" behavior.
    var failingLaunchSchemes: Set<String> = []
    private(set) var openedURLs: [URL] = []

    func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return installedSchemes.contains(scheme)
    }

    func launch(_ url: URL) async -> Bool {
        openedURLs.append(url)
        guard let scheme = url.scheme else { return true }
        return !failingLaunchSchemes.contains(scheme)
    }
}

@MainActor
struct TripNavigationLauncherTests {
    private let origin = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740) // Phoenix
    private let destination = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437) // LA
    private let fuelStop = CLLocationCoordinate2D(latitude: 33.9425, longitude: -114.1591) // Blythe, CA

    // MARK: - 1. Google Maps installed → native scheme selected, Safari never touched

    @Test("Google Maps installed selects the native comgooglemapsurl scheme, not the HTTPS URL")
    func googleMapsInstalled_selectsNativeScheme() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = ["comgooglemapsurl"]
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openGoogleMaps(for: .route(origin: origin, destination: destination, waypoints: [fuelStop])).value

        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs.first?.scheme == "comgooglemapsurl")
    }

    // MARK: - 2. Google Maps unavailable → HTTPS fallback selected, no crash, no dead button

    @Test("Google Maps not installed falls back to the HTTPS web URL")
    func googleMapsUnavailable_selectsHTTPSFallback() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = [] // nothing installed
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openGoogleMaps(for: .route(origin: origin, destination: destination, waypoints: [fuelStop])).value

        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs.first?.scheme == "https")
        #expect(opener.openedURLs.first?.host == "www.google.com")
    }

    // MARK: - 2b. Google Maps installed but the native open itself fails → HTTPS fallback
    // (regression test for the bug this fix addresses: canOpen(_:) reporting a scheme as
    // installed is not a guarantee UIApplication.open will actually succeed opening it —
    // before this fix, a failed native open had no way to report back and the button would
    // silently no-op instead of falling back.)

    @Test("Google Maps installed but native launch fails still falls back to the HTTPS URL")
    func googleMapsInstalledButLaunchFails_fallsBackToHTTPS() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = ["comgooglemapsurl"]
        opener.failingLaunchSchemes = ["comgooglemapsurl"]
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openGoogleMaps(for: .route(origin: origin, destination: destination, waypoints: [fuelStop])).value

        // Both the failed native attempt AND the fallback must have been launched, in order.
        #expect(opener.openedURLs.count == 2)
        #expect(opener.openedURLs.first?.scheme == "comgooglemapsurl")
        #expect(opener.openedURLs.last?.scheme == "https")
        #expect(opener.openedURLs.last?.host == "www.google.com")
    }

    // MARK: - 3. Waze installed → native scheme selected

    @Test("Waze installed selects the native waze:// scheme")
    func wazeInstalled_selectsNativeScheme() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = ["waze"]
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openWaze(for: .route(origin: origin, destination: destination, waypoints: [fuelStop])).value

        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs.first?.scheme == "waze")
    }

    // MARK: - 4. Waze unavailable → fallback behavior selected

    @Test("Waze not installed falls back to the HTTPS web URL")
    func wazeUnavailable_selectsHTTPSFallback() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = []
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openWaze(for: .singleStop(fuelStop, name: "Test Stop")).value

        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs.first?.scheme == "https")
        #expect(opener.openedURLs.first?.host == "waze.com")
    }

    // MARK: - 4b. Waze installed but the native open itself fails → HTTPS fallback
    // (comes for free from the shared openNativeThenFallback implementation both apps use.)

    @Test("Waze installed but native launch fails still falls back to the HTTPS URL")
    func wazeInstalledButLaunchFails_fallsBackToHTTPS() async {
        let opener = FakeURLOpener()
        opener.installedSchemes = ["waze"]
        opener.failingLaunchSchemes = ["waze"]
        TripNavigationLauncher.urlOpener = opener

        await TripNavigationLauncher.openWaze(for: .route(origin: origin, destination: destination, waypoints: [fuelStop])).value

        #expect(opener.openedURLs.count == 2)
        #expect(opener.openedURLs.first?.scheme == "waze")
        #expect(opener.openedURLs.last?.scheme == "https")
        #expect(opener.openedURLs.last?.host == "waze.com")
    }

    // MARK: - 5. Apple Maps — not covered by this file, deliberately

    // `TripNavigationLauncher.openAppleMaps` calls `MKMapItem.openMaps`/`.openInMaps` directly
    // — real UIKit/MapKit calls with no mockable seam, unlike Google Maps/Waze's URL-based
    // path above. Actually invoking them from a unit test would attempt a real app handoff
    // (at best a no-op outside a full app host, at worst a hang), so there is no meaningful,
    // fast, isolated test to write here without fabricating a result. This is a genuine gap,
    // not an oversight: Apple Maps was already correct before this fix (it never went through
    // `openURL`/an HTTPS URL, so it was never part of the reported bug) and this file's job is
    // regression coverage for what broke, not full coverage of everything the launcher does.
    // Its correctness is verified by code inspection (see TripNavigationLauncherTests's sibling
    // PR review) and by manual/physical-device QA, not by a test in this file.

    // MARK: - 6. URL construction: origin / destination / waypoints / coordinates

    @Test("Google Maps route URL contains origin, destination, and one fuel-stop waypoint")
    func googleMapsWebURL_route_withOneStop() throws {
        let url = try #require(TripNavigationLauncher.googleMapsWebURL(
            for: .route(origin: origin, destination: destination, waypoints: [fuelStop])
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(items["origin"] == "33.4484,-112.074")
        #expect(items["destination"] == "34.0522,-118.2437")
        #expect(items["waypoints"] == "33.9425,-114.1591")
        #expect(items["travelmode"] == "driving")
        #expect(items["api"] == "1")
    }

    @Test("Google Maps route URL with no recommended stop omits waypoints entirely")
    func googleMapsWebURL_route_withNoStop() throws {
        let url = try #require(TripNavigationLauncher.googleMapsWebURL(
            for: .route(origin: origin, destination: destination, waypoints: [])
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = (components.queryItems ?? []).map(\.name)

        #expect(names.contains("waypoints") == false)
        #expect(names.contains("origin"))
        #expect(names.contains("destination"))
    }

    @Test("Google Maps route URL with multiple stops joins them with a pipe, in order")
    func googleMapsWebURL_route_withMultipleStops_preservesOrder() throws {
        let secondStop = CLLocationCoordinate2D(latitude: 33.6, longitude: -113.0)
        let url = try #require(TripNavigationLauncher.googleMapsWebURL(
            for: .route(origin: origin, destination: destination, waypoints: [fuelStop, secondStop])
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let waypointsValue = components.queryItems?.first(where: { $0.name == "waypoints" })?.value

        #expect(waypointsValue == "33.9425,-114.1591|33.6,-113.0")
    }

    @Test("Google Maps native URL preserves every query item from the web URL, only the scheme changes")
    func googleMapsNativeURL_preservesQueryExactly() throws {
        let destinationValue = TripNavigationLauncher.Destination.route(origin: origin, destination: destination, waypoints: [fuelStop])
        let webURL = try #require(TripNavigationLauncher.googleMapsWebURL(for: destinationValue))
        let nativeURL = try #require(TripNavigationLauncher.googleMapsNativeURL(for: destinationValue))

        #expect(nativeURL.scheme == "comgooglemapsurl")
        #expect(webURL.scheme == "https")
        // Everything except the scheme must be identical — host, path, and every query item.
        let webComponents = try #require(URLComponents(url: webURL, resolvingAgainstBaseURL: false))
        let nativeComponents = try #require(URLComponents(url: nativeURL, resolvingAgainstBaseURL: false))
        #expect(nativeComponents.host == webComponents.host)
        #expect(nativeComponents.path == webComponents.path)
        #expect(nativeComponents.queryItems == webComponents.queryItems)
    }

    @Test("Google Maps single-stop URL uses the coordinate as destination with no waypoints")
    func googleMapsWebURL_singleStop() throws {
        let url = try #require(TripNavigationLauncher.googleMapsWebURL(for: .singleStop(fuelStop, name: "Blythe E85")))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(items["destination"] == "33.9425,-114.1591")
        #expect(items["origin"] == nil)
        #expect(items["waypoints"] == nil)
    }

    @Test("Waze route URL always targets the final destination, never the origin or a waypoint")
    func wazeWebURL_route_targetsDestinationOnly() throws {
        let url = try #require(TripNavigationLauncher.wazeWebURL(
            for: .route(origin: origin, destination: destination, waypoints: [fuelStop])
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let llValue = components.queryItems?.first(where: { $0.name == "ll" })?.value

        #expect(llValue == "34.0522,-118.2437")
        #expect(url.host == "waze.com")
    }

    @Test("Waze native URL has no host — just the query — matching Waze's documented scheme shape")
    func wazeNativeURL_hasNoHost() throws {
        let url = try #require(TripNavigationLauncher.wazeNativeURL(for: .singleStop(fuelStop, name: "Stop")))

        #expect(url.scheme == "waze")
        #expect(url.host == nil || url.host == "")
    }
}
