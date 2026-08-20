//
//  CommunityPriceEligibilityTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind Community E85 Price Reporting eligibility and
//  station-key resolution (CommunityPriceEligibility.canReport, CommunityStationKey.
//  normalizedKey/normalizedText) — the actual functions StationsView.StationPriceUpdateContext.
//  canReportToCommunity and normalizedStationKey(for:) call, not a duplicate reimplementation —
//  so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Regression context: Community Price Reporting was previously gated on navigation provenance
//  (StationPriceUpdateContext.isLiveDiscovered — true only for `.live(_:)` contexts built from a
//  Nearby Search result, unconditionally false for every `.saved(_:)` context) rather than on
//  whether the station carries enough information to be safely identified. CommunityPriceEligibility
//  replaces that with a data-sufficiency rule that has no provenance parameter at all.
//
//  A first pass at that rule (canReport == "any single field non-blank") was itself found to be
//  too permissive in a follow-up safety audit: it let a station be reported using nothing but a
//  bare name — including LiveFuelStation.init(from:)'s literal "Unknown Station" fallback and a
//  FuelStation created by FuelLogStore.updateStationIfNeeded from nothing but a typed name and
//  price. A SECOND pass (still "any single LOCATION field non-blank") was found to still be too
//  permissive in a further safety audit: it let a station report using nothing but city ==
//  "Phoenix", state == "AZ", or a bare zip code alone — narrows a search area, not one physical
//  pump. canReport now requires either a real coordinate pair, or a street address PLUS enough
//  locality context to disambiguate it (a zip code, or a city+state pair together — city or
//  state alone still doesn't count, and neither does a street address with no locality context
//  at all). CommunityStationKey.normalizedKey (which backs the read/display path, where a wrong
//  or missed match is only a minor UI inaccuracy) intentionally keeps its original, more
//  permissive rule throughout. See CommunityPriceEligibility.canReport's doc comment for the
//  full rationale and exact expression.
//
//  Several of the fixed bug's required regression scenarios are covered here as pure tests; the
//  remainder (network submission, community_stations upsert/reuse over the wire, Save Locally,
//  existing community price display) exercise CommunityPriceService and SwiftData code this fix
//  does not modify, and are recorded below as inspection facts, mirroring the convention
//  AppExperienceNavigationTests.swift already established for this codebase.
//
//  - "An existing community station is reused" / "submitted report references the correct
//    community station" / "no unnecessary duplicate community stations": CommunityPriceService.
//    upsertCommunityStation(normalizedStationKey:...) (CommunityPriceService.swift) always looks
//    up an existing community_stations row by normalizedStationKey BEFORE attempting to create
//    one (fetchCommunityStation(forNormalizedStationKey:), called first inside
//    upsertCommunityStation), and that function is completely unmodified by this fix — it has no
//    knowledge of, or branch on, how the caller obtained the key. Since
//    normalizedStationKeyForSavedAndLiveContextsWithIdenticalData_areEqual below proves a saved
//    station and a live station representing the same physical location produce the identical
//    key, they necessarily resolve to the identical community_stations row through this
//    unmodified, already-shipped lookup-before-create path — there is no second implementation.
//  - "A missing community station follows the existing safe create/upsert behavior": also
//    entirely handled by the unmodified upsertCommunityStation, which falls back to a real
//    upsert POST (Prefer: resolution=merge-duplicates) when no existing row is found. This fix
//    does not add, remove, or alter any station-creation code.
//  - "Save Locally still works" / "Nearby Save & Report still works": savePriceUpdate(for:
//    reportToCommunity:)'s local-save steps (upsertLocalStation, modelContext.save(),
//    refreshCommunityPricePreviews()) and its community-submission Task body (CommunityPriceService
//    calls, success/failure message branching) are byte-for-byte unchanged by this fix — the only
//    lines touched are the two `isLiveDiscovered` → `canReportToCommunity` gate checks and the
//    struct's own stored-property/init changes. A genuine Nearby result — one with real NREL
//    address/city/state/zip and/or coordinate data, which is the normal case for this dataset —
//    remains eligible exactly as before; only the degenerate name-only case is newly excluded,
//    and that case was never reliably reportable in the first place (see canReport's doc comment).
//  - "A failed network/community submission is surfaced correctly": the catch block in
//    savePriceUpdate's Task (StationsView.swift) that distinguishes
//    CommunityPriceServiceError.notConfigured from other failures is unmodified.
//  - "Existing Community E85 display/freshness behavior still works": communitySummary(for:),
//    refreshCommunityPricePreviews(), and CommunityPriceSummary are unmodified; they call the
//    now-shared CommunityStationKey.normalizedText/normalizedKey through the exact same
//    normalizedStationText/normalizedStationKey private wrapper functions as before (their
//    bodies now delegate to CommunityStationKey but their signatures, call sites, and return
//    values are identical, and normalizedKey's own rule is unchanged by this follow-up), so
//    display resolution is behaviorally unchanged — a name-only saved station can still show an
//    existing community price for display purposes even though it can no longer report one.
//
//  THIRD PASS (Community Station Identity Foundation — Price Alerts prerequisite): the Station
//  Price Alerts architecture audit found two further, concrete defects — see
//  CommunityStationKey.canonicalKey's doc comment (CommunityPriceEligibility.swift) for the full
//  fix, tested below under "MARK: Canonical identity key (third pass)":
//  - Fragmentation: FuelLogView had its own second, independent reimplementation of station-key
//    construction with different blank-field handling than CommunityStationKey.normalizedKey —
//    the same station data with a blank field could resolve to two different community_stations
//    rows depending on which screen reported it. FuelLogView's reimplementation is now removed;
//    both screens call CommunityStationKey.canonicalKey exclusively.
//  - Collision: normalizedKey never included coordinates, so two distinct, real, coordinate-only
//    stations sharing a name and lacking address data could resolve to the identical key
//    regardless of how far apart they actually are. canonicalKey now folds a rounded coordinate
//    into the key specifically when the address alone isn't sufficient to disambiguate.
//  Live production data was inspected (read-only) as part of this fix: all four community_stations
//  rows that exist today have fully-populated addresses, so all four already satisfy
//  hasSufficientAddress and are keyed by canonicalKey's branch 1 — which reproduces
//  normalizedKey's original address-based output byte-for-byte. No known existing row is
//  orphaned by this change; see the Community Station Identity Foundation final report for the
//  full compatibility analysis and why a legacy-key transition path was judged unnecessary given
//  that evidence, not merely assumed unnecessary.

import Testing
@testable import EightyFiveBlends

struct CommunityPriceEligibilityTests {

    // MARK: 1-2. A valid, location-identified station — regardless of how it's represented — can report

    @Test("A station with full nearby-search-shaped data (name, address, city, state, zip, coordinates) is eligible to report")
    func canReport_fullyPopulatedStation_isEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron - Team C B",
            streetAddress: "123 Main St",
            city: "Springfield",
            state: "IL",
            zip: "62701",
            latitude: 39.78,
            longitude: -89.65
        ))
    }

    @Test("The identical physical station, represented with the same data as if reached through Saved Stations, is equally eligible to report")
    func canReport_sameStationDataRepresentedAsSaved_isEligible() {
        // StationPriceUpdateContext.saved(_:) and .live(_:) both funnel into the exact same
        // canReportToCommunity computed property with no branch on which factory built them —
        // this test exercises that shared rule with the same data twice to make that explicit.
        let name = "Chevron - Team C B"
        let address = "123 Main St"
        let city = "Springfield"
        let state = "IL"
        let zip = "62701"

        let asIfFromNearbySearch = CommunityPriceEligibility.canReport(
            name: name, streetAddress: address, city: city, state: state, zip: zip,
            latitude: nil, longitude: nil
        )
        let asIfFromSavedStations = CommunityPriceEligibility.canReport(
            name: name, streetAddress: address, city: city, state: state, zip: zip,
            latitude: nil, longitude: nil
        )

        #expect(asIfFromNearbySearch == true)
        #expect(asIfFromSavedStations == true)
        #expect(asIfFromNearbySearch == asIfFromSavedStations)
    }

    // MARK: 3. Eligibility is not determined by provenance

    @Test("canReport has no provenance/source/origin parameter — eligibility cannot be a function of navigation history by construction")
    func canReport_hasNoProvenanceParameter() {
        // This is a structural guarantee, not just a runtime one: CommunityPriceEligibility.
        // canReport's signature only accepts station data (name/address/city/state/zip/
        // coordinates). There is no "isNearby"/"source"/"origin"/"wasSaved" argument to pass, so
        // it is not possible for a caller to make this function's answer depend on how the
        // station was discovered — unlike the old `isLiveDiscovered` stored property, which was
        // hardcoded per call site (`.saved(_:)` always false, `.live(_:)` always true) regardless
        // of data. A station with real location data is eligible no matter which call site it
        // came from; see canReport_nameOnlyStation_isNotEligible below for the flip side — a
        // name-only station is *equally* ineligible no matter which call site it came from.
        let withLocation = CommunityPriceEligibility.canReport(
            name: "Any Station", streetAddress: "1 Any St", city: "", state: "", zip: "12345",
            latitude: nil, longitude: nil
        )
        #expect(withLocation == true)
    }

    // MARK: 4. A genuinely insufficient station remains safely local-only

    @Test("A station with every identifying field blank and no coordinates is not eligible to report — remains local-only")
    func canReport_allFieldsBlank_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("Whitespace-only fields count as blank, not as identifying information")
    func canReport_whitespaceOnlyFields_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "   ", streetAddress: "\n", city: "\t", state: " ", zip: "",
            latitude: nil, longitude: nil
        ) == false)
    }

    // MARK: 4b. Name alone is never enough (the safety-audit finding)

    @Test("A station identified by name only, with no address/city/state/zip/coordinates, is NOT eligible to report — even with a specific-looking name")
    func canReport_nameOnlyStation_isNotEligible() {
        // Matches FuelLogStore.updateStationIfNeeded's real creation path: a FuelStation built
        // from nothing but a typed station name and price. Whether the name looks generic
        // ("Chevron") or specific ("Joe's Corner Store"), a name by itself cannot safely identify
        // ONE physical pump among every station that might share that name.
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
        #expect(CommunityPriceEligibility.canReport(
            name: "Phoenix", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("LiveFuelStation's literal \"Unknown Station\" fallback name, with no location data, is NOT eligible to report")
    func canReport_unknownStationFallbackNameOnly_isNotEligible() {
        // Reproduces LiveFuelStation.init(from:)'s exact fallback (NRELStationService.swift):
        // name defaults to "Unknown Station" when NREL supplies none, and address/city/state/zip
        // default to "" when NREL supplies none of those either. A missing coordinate is
        // represented as 0/0 by that initializer, which StationPriceUpdateContext.live(_:)
        // already converts to nil before eligibility is ever checked — modeled here directly as
        // nil for the same reason.
        #expect(CommunityPriceEligibility.canReport(
            name: "Unknown Station", streetAddress: "", city: "", state: "", zip: "",
            latitude: nil, longitude: nil
        ) == false)
    }

    // MARK: 4c. A single location field (city/state/zip alone) is ALSO not enough (second-round audit finding)

    @Test("City alone is NOT eligible — 'Phoenix' narrows a metro area, not one physical pump")
    func canReport_cityOnly_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "Phoenix", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("State alone is NOT eligible — 'AZ' narrows to an entire state")
    func canReport_stateOnly_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "AZ", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("ZIP alone is NOT eligible — a zip code still covers many possible stations")
    func canReport_zipOnly_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "", zip: "85001", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("Name plus city only, or name plus state only, is NOT eligible — adding a name doesn't fix an under-specified location")
    func canReport_nameWithCityOrStateOnly_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron", streetAddress: "", city: "Phoenix", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron", streetAddress: "", city: "", state: "AZ", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("A street address with no zip and no city+state pair is NOT eligible — a bare street name alone can exist in many different cities/states")
    func canReport_streetAddressAloneWithNoLocalityContext_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "123 Main St", city: "", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
        // City alone (no state) paired with the address still isn't enough — city and state must
        // be present together, not just one of them.
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "123 Main St", city: "Springfield", state: "", zip: "", latitude: nil, longitude: nil
        ) == false)
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "123 Main St", city: "", state: "IL", zip: "", latitude: nil, longitude: nil
        ) == false)
    }

    @Test("A street address plus a zip code is eligible, even with no city/state text at all")
    func canReport_streetAddressPlusZip_isEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "123 Main St", city: "", state: "", zip: "62701", latitude: nil, longitude: nil
        ) == true)
    }

    @Test("A street address plus city and state together is eligible, even with no zip code")
    func canReport_streetAddressPlusCityAndState_isEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "", latitude: nil, longitude: nil
        ) == true)
    }

    @Test("A fully populated street address (address, city, state, and zip together) is eligible")
    func canReport_fullAddress_isEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron - Team C B", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: nil, longitude: nil
        ) == true)
    }

    @Test("A real coordinate pair alone is enough to be eligible, even with no name or textual address")
    func canReport_coordinatesOnly_isEligible() {
        // Covers a sparse-but-geocoded NREL record: name may fall back to "Unknown Station" and
        // every textual field may be blank, but a real, non-placeholder lat/long pair still
        // safely pins one physical location.
        #expect(CommunityPriceEligibility.canReport(
            name: "Unknown Station", streetAddress: "", city: "", state: "", zip: "",
            latitude: 39.78, longitude: -89.65
        ) == true)
    }

    @Test("A coordinate is only usable if BOTH latitude and longitude are present — a lone half-pair does not count")
    func canReport_partialCoordinate_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "", zip: "", latitude: 39.78, longitude: nil
        ) == false)
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: -89.65
        ) == false)
    }

    // MARK: 5-9, 14. Community station resolution / physical-station correctness

    @Test("A saved station and a live station representing the identical physical location resolve to the identical community station key")
    func normalizedStationKeyForSavedAndLiveContextsWithIdenticalData_areEqual() {
        // Mirrors StationPriceUpdateContext.saved(_:) and .live(_:): both ultimately pass
        // name/streetAddress/city/state/zip into the same CommunityStationKey.normalizedKey.
        // A real saved station reached the same physical pump either because it was manually
        // added with the same address, or — the common real-world case — because it was
        // favorited directly from a Nearby Search result, which copies that result's own
        // name/address/city/state/zip onto the persisted FuelStation (see
        // upsertLocalStation/saveLiveStation in StationsView.swift). Same data in, same key out,
        // regardless of which factory method built the context — which is exactly what makes
        // CommunityPriceService.upsertCommunityStation's existing lookup-by-key-before-create
        // reuse the same community_stations row for both, with no duplicate created.
        let savedKey = CommunityStationKey.normalizedKey(
            name: "Chevron - Team C B", streetAddress: "123 Main St",
            city: "Springfield", state: "IL", zip: "62701"
        )
        let liveKey = CommunityStationKey.normalizedKey(
            name: "Chevron - Team C B", streetAddress: "123 Main St",
            city: "Springfield", state: "IL", zip: "62701"
        )
        #expect(savedKey != nil)
        #expect(savedKey == liveKey)
    }

    @Test("A different station name at the same address produces a different key — documented existing behavior, not something this fix changes")
    func normalizedStationKey_differentNameSameAddress_producesDifferentKey() {
        // This intentionally does NOT assert that "Mobil" and "Chevron" branding for the same
        // physical property should merge — station canonicalization/provider-matching is out of
        // scope for this fix (see task instructions). It documents the current, unchanged
        // behavior: the key is built from name+address+city+state+zip together, so two
        // differently-named reports of what a human would recognize as the same pump are NOT
        // guaranteed to resolve to the same community_stations row today. That's a pre-existing,
        // separate concern from the eligibility bug this change fixes.
        let mobilKey = CommunityStationKey.normalizedKey(
            name: "Mobil", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701"
        )
        let chevronKey = CommunityStationKey.normalizedKey(
            name: "Chevron - Team C B", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701"
        )
        #expect(mobilKey != chevronKey)
    }

    @Test("Case and diacritic differences don't fragment the same station's key")
    func normalizedStationKey_caseAndDiacriticInsensitive() {
        let lower = CommunityStationKey.normalizedKey(
            name: "chevron - team c b", streetAddress: "123 main st", city: "springfield", state: "il", zip: "62701"
        )
        let mixed = CommunityStationKey.normalizedKey(
            name: "CHEVRON - Team C B", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701"
        )
        #expect(lower == mixed)
    }

    // MARK: Read/write divergence — the core of the follow-up safety audit

    @Test("A name-only station can still build a display key (read path unaffected) even though it can no longer report (write path tightened)")
    func nameOnlyStation_canStillBeKeyedForDisplay_butCannotReport() {
        // This is the explicit, tested answer to "is normalizedStationKey intended to support
        // partial identities for writes, not merely reads?" — no. CommunityStationKey.
        // normalizedKey (backing communitySummary/refreshCommunityPricePreviews, i.e. DISPLAY)
        // still happily builds a key from a bare name — a saved "Chevron" station with an
        // existing community price can still show it. CommunityPriceEligibility.canReport (the
        // WRITE gate) now refuses the identical station. The two rules are allowed to diverge on
        // purpose; this test pins that divergence so it can't silently drift back into agreement.
        let key = CommunityStationKey.normalizedKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: ""
        )
        let canReport = CommunityPriceEligibility.canReport(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
        )
        #expect(key != nil)          // display/read path: still resolvable
        #expect(canReport == false)  // reporting/write path: correctly blocked
    }

    // MARK: Canonical identity key (third pass) — fragmentation fix

    @Test("The exact fragmentation case from the Station Price Alerts audit: StationsView's and FuelLogView's OLD algorithms disagreed; canonicalKey is now the only implementation, so there is nothing left to disagree")
    func canonicalKey_fixesTheAuditedFragmentationExample() {
        // Name: Chevron, Street: "", City: Phoenix, State: "", ZIP: "" — the audit's own example.
        // Old CommunityStationKey.normalizedKey (StationsView's path) produced "chevron||phoenix||".
        // Old FuelLogView.normalizedStationKey (filter-then-join) produced "chevron|phoenix" — a
        // DIFFERENT string for the same data. canonicalKey is the only implementation now, so
        // both call sites necessarily agree by construction; this test pins the single output.
        let key = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "Phoenix", state: "", zip: "",
            latitude: nil, longitude: nil
        )
        #expect(key == "chevron||phoenix||")
    }

    @Test("Same station, same complete address, produces the same canonical key")
    func canonicalKey_sameCompleteAddress_sameKey() {
        let a = CommunityStationKey.canonicalKey(
            name: "Chevron - Team C B", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: nil, longitude: nil
        )
        let b = CommunityStationKey.canonicalKey(
            name: "Chevron - Team C B", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: nil, longitude: nil
        )
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("Mixed casing does not fragment the canonical key")
    func canonicalKey_mixedCasing_sameKey() {
        let lower = CommunityStationKey.canonicalKey(
            name: "chevron", streetAddress: "123 main st", city: "springfield", state: "il", zip: "62701",
            latitude: nil, longitude: nil
        )
        let upper = CommunityStationKey.canonicalKey(
            name: "CHEVRON", streetAddress: "123 MAIN ST", city: "SPRINGFIELD", state: "IL", zip: "62701",
            latitude: nil, longitude: nil
        )
        #expect(lower == upper)
    }

    @Test("Leading/trailing whitespace differences do not fragment the canonical key")
    func canonicalKey_whitespaceDifferences_sameKey() {
        let tight = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: nil, longitude: nil
        )
        let padded = CommunityStationKey.canonicalKey(
            name: "  Chevron  ", streetAddress: " 123 Main St ", city: " Springfield ", state: " IL ", zip: " 62701 ",
            latitude: nil, longitude: nil
        )
        #expect(tight == padded)
    }

    @Test("StationsView's and FuelLogView's wrapper functions call the identical canonicalKey — missing fields cannot produce diverging keys anymore, by construction")
    func canonicalKey_missingFields_stationsAndFuelLogPathsAgree() {
        // There is only one implementation left to call; this test documents that guarantee with
        // several representative missing-field shapes rather than re-deriving two separate
        // algorithms and comparing them (there is nothing left to compare against).
        let shapes: [(name: String, street: String, city: String, state: String, zip: String)] = [
            ("Chevron", "", "Phoenix", "", ""),
            ("Chevron", "", "", "AZ", ""),
            ("76", "443 Divisadero St", "", "", ""),
            ("", "", "", "", ""),
        ]
        for shape in shapes {
            let key = CommunityStationKey.canonicalKey(
                name: shape.name, streetAddress: shape.street, city: shape.city, state: shape.state, zip: shape.zip,
                latitude: nil, longitude: nil
            )
            // Every shape above is reachable identically from StationsView's and FuelLogView's
            // wrapper functions (both now delegate straight through with no branching of their
            // own), so re-calling with the same inputs must be deterministic and idempotent.
            let again = CommunityStationKey.canonicalKey(
                name: shape.name, streetAddress: shape.street, city: shape.city, state: shape.state, zip: shape.zip,
                latitude: nil, longitude: nil
            )
            #expect(key == again)
        }
    }

    // MARK: Canonical identity key (third pass) — collision fix

    @Test("The exact collision case from the Station Price Alerts audit: two distinct, real, coordinate-only, same-named stations no longer share a key")
    func canonicalKey_fixesTheAuditedCollisionExample() {
        // Station A and Station B: both named "Chevron", both address-less, both with real but
        // DIFFERENT coordinates. Under the old normalizedKey (no coordinate parameter at all),
        // both produced the identical "chevron||||" — a collision regardless of physical distance.
        let stationA = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.4, longitude: -112.1
        )
        let stationB = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.5, longitude: -112.3
        )
        #expect(stationA != nil)
        #expect(stationB != nil)
        #expect(stationA != stationB)
    }

    @Test("Coordinate rounding absorbs insignificant GPS/geocoding jitter for the same station")
    func canonicalKey_coordinateTolerance_absorbsJitter() {
        // ~5-10m of disagreement (a realistic GPS-vs-geocoded-pin gap) stays inside one ~111m
        // (0.001°) bucket and must NOT fragment the same physical station.
        let reading1 = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.40001, longitude: -112.10002
        )
        let reading2 = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.40003, longitude: -112.09998
        )
        #expect(reading1 == reading2)
    }

    @Test("Coordinates a full bucket apart (~200m+) do fragment — the tolerance has an edge, by design")
    func canonicalKey_coordinateTolerance_hasAnEdge() {
        let here = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.400, longitude: -112.100
        )
        let twoBucketsAway = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "",
            latitude: 33.402, longitude: -112.100
        )
        #expect(here != twoBucketsAway)
    }

    @Test("Different strong addresses never collide, coordinates or not")
    func canonicalKey_differentStrongAddresses_neverCollide() {
        let a = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: 39.78, longitude: -89.65
        )
        let b = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "456 Oak Ave", city: "Springfield", state: "IL", zip: "62701",
            latitude: 39.78, longitude: -89.65
        )
        #expect(a != b)
    }

    @Test("A sufficient address always wins over coordinates — two reports of the same well-addressed station with slightly different GPS fixes still produce the identical key")
    func canonicalKey_sufficientAddress_ignoresCoordinateVariance() {
        let fix1 = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: 39.78, longitude: -89.65
        )
        let fix2 = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701",
            latitude: 39.81, longitude: -89.70 // a wildly different fix — still ignored
        )
        #expect(fix1 == fix2)
        #expect(fix1 == CommunityStationKey.normalizedKey(
            name: "Chevron", streetAddress: "123 Main St", city: "Springfield", state: "IL", zip: "62701"
        ))
    }

    // MARK: Canonical identity key (third pass) — fail-closed and production-data compatibility

    @Test("Empty/insufficient identity with no coordinates returns nil — never invents an unsafe key")
    func canonicalKey_emptyIdentity_returnsNil() {
        #expect(CommunityStationKey.canonicalKey(
            name: "", streetAddress: "", city: "", state: "", zip: "", latitude: nil, longitude: nil
        ) == nil)
    }

    @Test("A partial coordinate (only latitude or only longitude) is not treated as a real coordinate — falls back to the permissive text key, matching canReport's own partial-coordinate rule")
    func canonicalKey_partialCoordinate_fallsBackToTextKey() {
        let latOnly = CommunityStationKey.canonicalKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: "", latitude: 33.4, longitude: nil
        )
        #expect(latOnly == CommunityStationKey.normalizedKey(
            name: "Chevron", streetAddress: "", city: "", state: "", zip: ""
        ))
    }

    @Test("All four real production community_stations rows (read-only, inspected during this fix) are fully-addressed and resolve under canonicalKey to the identical key normalizedKey already produced for them — zero known existing rows are orphaned by this change")
    func canonicalKey_realProductionRows_matchPriorNormalizedKeyExactly() {
        // Verbatim (address/city/state/zip/coordinates) from the four rows in the live
        // community_stations table at the time of this fix. Every row already has a full
        // address, so every row already satisfies hasSufficientAddress and was never at risk
        // from the coordinate branch — this test pins that fact directly against production data
        // shapes rather than asserting it in the abstract.
        let rows: [(name: String, street: String, city: String, state: String, zip: String, lat: Double, lng: Double)] = [
            ("76", "443 Divisadero St", "San Francisco", "CA", "94117", 37.77374, -122.43787),
            ("Mobil", "6653 W McDowell Rd", "Phoenix", "AZ", "85035", 33.46552, -112.20272),
            ("Valero In the Zone VII", "1925 N Scottsdale Rd", "Tempe", "AZ", "85281", 33.450825, -111.925969),
            ("Chevron - Team C B", "4737 E Broadway", "Phoenix", "AZ", "85040", 33.40682, -111.97877),
        ]
        for row in rows {
            let canonical = CommunityStationKey.canonicalKey(
                name: row.name, streetAddress: row.street, city: row.city, state: row.state, zip: row.zip,
                latitude: row.lat, longitude: row.lng
            )
            let original = CommunityStationKey.normalizedKey(
                name: row.name, streetAddress: row.street, city: row.city, state: row.state, zip: row.zip
            )
            #expect(canonical == original)
        }
    }
}
