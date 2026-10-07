//
//  PriceAlertsAutomaticTriggerTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the rule that automatic triggers (launch, returning to the app, an APNs
//  token callback) only MAINTAIN a device registration that already exists, and never create an
//  installation. An installation is a new identity on the server; creating one takes a person
//  (`enablePushDelivery()`), whatever the Pro state, whatever the local record says.
//
//  Runs over the Phase 3A fakes. No network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let tokenA = FakePushState.token(0xA1)

struct PriceAlertsAutomaticTriggerTests {
    /// A Pro user whose local registration record survived (say, restored from a backup) but whose
    /// Keychain credential did not — the one state in which an automatic trigger would otherwise have
    /// had to create an installation to proceed.
    private func orphanedRecord(entitlement: PriceAlertsEntitlement = .active) -> PriceAlertsStack {
        let stack = PriceAlertsStack(push: .registered(tokenA), entitlement: entitlement)
        stack.records.record = PriceAlertsDeviceRegistrationRecord(fingerprint: "restored", registeredAt: stack.clock.now)
        return stack
    }

    @Test("Returning to the app never creates an installation, even for a Pro user whose record outlived the credential")
    func foreground_neverCreatesAnInstallation() async {
        let stack = orphanedRecord()

        let outcome = await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered()

        #expect(outcome == .skipped(.notOptedIn))
        #expect(stack.transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
        #expect(stack.identity.callCount == 0)
        #expect(stack.push.optInCount == 0)
        #expect(stack.service.lastDeviceRegistrationOutcome == nil)
    }

    @Test("A token callback never creates an installation either")
    func tokenCallback_neverCreatesAnInstallation() async {
        let stack = orphanedRecord()

        let outcome = await stack.service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered()

        #expect(outcome == .skipped(.notOptedIn))
        #expect(stack.transport.requests.isEmpty)
        #expect(stack.credentials.saveCount == 0)
        #expect(stack.push.refreshCount == 0)
    }

    @Test("Nor does a lapsed or still-unresolved subscriber's app-level reconcile")
    func notProEither() async {
        for entitlement in [PriceAlertsEntitlement.inactive, .unresolved] {
            let stack = orphanedRecord(entitlement: entitlement)

            #expect(await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .skipped(.notOptedIn))
            #expect(await stack.service.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() == .skipped(.notOptedIn))

            #expect(stack.transport.requests.isEmpty)
            #expect(stack.credentials.saveCount == 0)
        }
    }

    @Test("A person's own action does create it: opting in is what turns a record-less or credential-less install into a registered one")
    func personCan() async {
        let stack = orphanedRecord()

        let outcome = await stack.service.enablePushDelivery()

        #expect(outcome == .registered)
        #expect(stack.credentials.saveCount == 1)
        #expect(stack.transport.actions == ["bootstrap", "register_device"])
        // And from then on the automatic triggers have an installation to maintain.
        stack.push.pushState = .registered(FakePushState.token(0xB2))
        #expect(await stack.service.reconcileDeviceRegistrationIfPreviouslyRegistered() == .registered)
    }

    @Test("A screen's explicit refresh (user-initiated) may still bring an install back into step")
    func explicitRefresh_isNotAutomatic() async {
        let stack = PriceAlertsStack(push: .registered(tokenA))

        #expect(await stack.service.reconcileDeviceRegistration() == .registered)
        #expect(stack.transport.count(of: "register_device") == 1)
    }
}
