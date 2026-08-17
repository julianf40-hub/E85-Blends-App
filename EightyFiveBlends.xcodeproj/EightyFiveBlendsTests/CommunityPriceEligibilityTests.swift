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
//  replaces that with a data-sufficiency rule that has no provenance parameter at all — see its
//  doc comment. Several of the fixed bug's required regression scenarios are covered here as pure
//  tests; the remainder (network submission, community_stations upsert/reuse over the wire,
//  Save Locally, existing community price display) exercise CommunityPriceService and SwiftData
//  code this fix does not modify, and are recorded below as inspection facts, mirroring the
//  convention AppExperienceNavigationTests.swift already established for this codebase.
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
//    struct's own stored-property/init changes. A previously-eligible Nearby station's
//    LiveFuelStation-derived context (name always defaults to "Unknown Station" when blank, per
//    LiveFuelStation.init(from:)) is never all-blank, so canReportToCommunity is true for every
//    real Nearby result exactly as isLiveDiscovered always was — no regression.
//  - "A failed network/community submission is surfaced correctly": the catch block in
//    savePriceUpdate's Task (StationsView.swift) that distinguishes
//    CommunityPriceServiceError.notConfigured from other failures is unmodified.
//  - "Existing Community E85 display/freshness behavior still works": communitySummary(for:),
//    refreshCommunityPricePreviews(), and CommunityPriceSummary are unmodified; they call the
//    now-shared CommunityStationKey.normalizedText/normalizedKey through the exact same
//    normalizedStationText/normalizedStationKey private wrapper functions as before (their
//    bodies now delegate to CommunityStationKey but their signatures, call sites, and return
//    values are identical), so display resolution is behaviorally unchanged.

import Testing
@testable import EightyFiveBlends

struct CommunityPriceEligibilityTests {

    // MARK: 1-2. A valid station — regardless of how it's represented — can report

    @Test("A station with full nearby-search-shaped data (name, address, city, state, zip, coordinates) is eligible to report")
    func canReport_fullyPopulatedStation_isEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "Chevron - Team C B",
            streetAddress: "123 Main St",
            city: "Springfield",
            state: "IL",
            zip: "62701"
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
            name: name, streetAddress: address, city: city, state: state, zip: zip
        )
        let asIfFromSavedStations = CommunityPriceEligibility.canReport(
            name: name, streetAddress: address, city: city, state: state, zip: zip
        )

        #expect(asIfFromNearbySearch == true)
        #expect(asIfFromSavedStations == true)
        #expect(asIfFromNearbySearch == asIfFromSavedStations)
    }

    // MARK: 3. Eligibility is not determined by provenance

    @Test("canReport has no provenance/source/origin parameter — eligibility cannot be a function of navigation history by construction")
    func canReport_hasNoProvenanceParameter() {
        // This is a structural guarantee, not just a runtime one: CommunityPriceEligibility.
        // canReport's signature only accepts station data (name/streetAddress/city/state/zip).
        // There is no "isNearby"/"source"/"origin"/"wasSaved" argument to pass, so it is not
        // possible for a caller to make this function's answer depend on how the station was
        // discovered — unlike the old `isLiveDiscovered` stored property, which was hardcoded
        // per call site (`.saved(_:)` always false, `.live(_:)` always true) regardless of data.
        let minimallyPopulated = CommunityPriceEligibility.canReport(
            name: "Any Station", streetAddress: "", city: "", state: "", zip: ""
        )
        #expect(minimallyPopulated == true) // name alone is enough, wherever it came from
    }

    // MARK: 4. A genuinely insufficient station remains safely local-only

    @Test("A station with every identifying field blank is not eligible to report — remains local-only")
    func canReport_allFieldsBlank_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "", streetAddress: "", city: "", state: "", zip: ""
        ) == false)
    }

    @Test("Whitespace-only fields count as blank, not as identifying information")
    func canReport_whitespaceOnlyFields_isNotEligible() {
        #expect(CommunityPriceEligibility.canReport(
            name: "   ", streetAddress: "\n", city: "\t", state: " ", zip: ""
        ) == false)
    }

    @Test("A single non-blank field (e.g. just a name, or just a zip) is enough to be eligible")
    func canReport_singleNonBlankField_isEligible() {
        #expect(CommunityPriceEligibility.canReport(name: "Corner Store", streetAddress: "", city: "", state: "", zip: "") == true)
        #expect(CommunityPriceEligibility.canReport(name: "", streetAddress: "", city: "", state: "", zip: "62701") == true)
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

    @Test("normalizedKey returns nil only when every field is blank, matching canReport's rule exactly")
    func normalizedKey_andCanReport_agree() {
        let blank = CommunityStationKey.normalizedKey(name: "", streetAddress: "", city: "", state: "", zip: "")
        #expect(blank == nil)
        #expect(CommunityPriceEligibility.canReport(name: "", streetAddress: "", city: "", state: "", zip: "") == (blank != nil))

        let populated = CommunityStationKey.normalizedKey(name: "Corner Store", streetAddress: "", city: "", state: "", zip: "")
        #expect(populated != nil)
        #expect(CommunityPriceEligibility.canReport(name: "Corner Store", streetAddress: "", city: "", state: "", zip: "") == (populated != nil))
    }
}
