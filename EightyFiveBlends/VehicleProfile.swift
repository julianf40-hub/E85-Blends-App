//
//  VehicleProfile.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class VehicleProfile {
    // Every non-optional attribute carries an inline default value. SwiftData's CloudKit
    // schema generation requires each attribute to be optional OR have a default at the
    // property declaration (init defaults are not enough), so these defaults are what let
    // the CloudKit-backed container initialize. The values mirror the init defaults exactly,
    // so the stored shape is unchanged and existing data migrates cleanly.
    var nickname: String = ""
    var year: String = ""
    var make: String = ""
    var model: String = ""
    var trim: String = ""
    var tankSizeGallons: Double = 0
    var currentOdometer: Int = 0

    // MARK: - Legacy calculator-default fields (85Blends 2.3.0 Garage simplification)
    //
    // These four properties used to be edited directly in the Add/Edit Vehicle form and read as
    // normal calculator preferences. As of 2.3.0 they are FROZEN, persistence-only compatibility
    // columns:
    //   - No UI writes to them anymore — Add/Edit Vehicle and Onboarding no longer show these
    //     fields, and GarageView.saveVehicle no longer assigns them on edit.
    //   - No calculator/pump/cost-calculator code reads them as a normal preference anymore —
    //     every consumer now goes through FuelPreferenceResolution.swift instead.
    //   - defaultTargetEthanolPercent is the ONE exception: for a vehicle whose
    //     calculatorPreferenceSemanticsVersion is still `legacy` (0), this field IS still that
    //     vehicle's real, effective preferred target — see
    //     FuelPreferenceResolution.PreferredTargetResolution. Existing users' saved targets keep
    //     working exactly as before until the vehicle is next saved through the Edit Vehicle
    //     form, which transitions it to semantics version 1.
    //
    // Do NOT remove, rename, or repurpose these — per the existing precedent set by
    // MaintenanceReminder.purchaseURLString/reminderIdentifier, removing a persisted SwiftData/
    // CloudKit property is a destructive schema change with no rollback path. They are kept
    // solely so existing users' data survives this update untouched.
    var defaultTargetEthanolPercent: Double = 30
    var defaultCurrentEthanolPercent: Double = 10
    var defaultPumpEthanolPercent: Double = 85
    var gasEthanolPercent: Double = 10

    // MARK: - Current calculator-preference fields (2.3.0+)

    /// The user's optional starting target for the Blend Calculator. `nil` means "no
    /// preference" — this must NEVER be treated as equivalent to E0, E10, E30, or any other
    /// specific percentage. See FuelPreferenceResolution.PreferredTargetResolution for the
    /// actual fallback chain a `nil` value falls through to. Only meaningful when
    /// `calculatorPreferenceSemanticsVersion >= 1` (see below); for a legacy vehicle,
    /// `defaultTargetEthanolPercent` above is the effective preference instead.
    var preferredEthanolTargetPercent: Double?

    /// Distinguishes a vehicle that predates 85Blends 2.3.0 (or has never been re-saved since)
    /// from one created/edited under the new semantics:
    ///   - `0` (legacy): `defaultTargetEthanolPercent` is this vehicle's real preference. Every
    ///     vehicle that existed before this property was introduced reads as `0` automatically —
    ///     SwiftData's lightweight migration fills the new column with its inline default for
    ///     every existing row, so no migration code has to run for this to be correct.
    ///   - `1` (current): `preferredEthanolTargetPercent` is authoritative instead.
    /// See VehiclePreferenceSemantics in FuelPreferenceResolution.swift for the named constants,
    /// and GarageView.saveVehicle for where a vehicle transitions from 0 to 1.
    var calculatorPreferenceSemanticsVersion: Int = 0

    var requiredOctane: Double = 91
    var isFlexFuel: Bool = false
    var isActive: Bool = false
    @Attribute(.externalStorage)
    var vehiclePhotoData: Data?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        nickname: String = "",
        year: String = "",
        make: String = "",
        model: String = "",
        trim: String = "",
        tankSizeGallons: Double = 0,
        currentOdometer: Int = 0,
        defaultTargetEthanolPercent: Double = 30,
        defaultCurrentEthanolPercent: Double = 10,
        defaultPumpEthanolPercent: Double = 85,
        gasEthanolPercent: Double = 10,
        requiredOctane: Double = 91,
        isFlexFuel: Bool = false,
        isActive: Bool = false,
        vehiclePhotoData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        preferredEthanolTargetPercent: Double? = nil,
        calculatorPreferenceSemanticsVersion: Int = 0
    ) {
        self.nickname = nickname
        self.year = year
        self.make = make
        self.model = model
        self.trim = trim
        self.tankSizeGallons = tankSizeGallons
        self.currentOdometer = currentOdometer
        self.defaultTargetEthanolPercent = defaultTargetEthanolPercent
        self.defaultCurrentEthanolPercent = defaultCurrentEthanolPercent
        self.defaultPumpEthanolPercent = defaultPumpEthanolPercent
        self.gasEthanolPercent = gasEthanolPercent
        self.requiredOctane = requiredOctane
        self.isFlexFuel = isFlexFuel
        self.isActive = isActive
        self.vehiclePhotoData = vehiclePhotoData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preferredEthanolTargetPercent = preferredEthanolTargetPercent
        self.calculatorPreferenceSemanticsVersion = calculatorPreferenceSemanticsVersion
    }
}
