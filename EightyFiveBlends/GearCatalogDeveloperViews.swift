//
//  GearCatalogDeveloperViews.swift
//  EightyFiveBlends
//
//  Tester controls for previewing a staging Recommended Gear catalog. Compiled into every build,
//  but rendered only while GearCatalogStore.previewEligibility is .eligible (TestFlight, Xcode and
//  Debug builds); the store itself rejects every staging operation otherwise, so hiding the UI is
//  not the protection. Nothing here holds or sends credentials: staging is a public object in the
//  same bucket, read exactly like production.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension GearCatalogStore.RefreshOutcome {
    var developerDescription: String {
        switch self {
        case .updated: return "Updated"
        case .unchanged: return "Unchanged"
        case .notModified: return "Not modified (304)"
        case .throttled: return "Throttled"
        case .inProgress: return "In progress"
        case .notConfigured: return "Not configured (no Supabase URL)"
        case .superseded: return "Discarded (source switched)"
        case .previewUnavailable: return "Staging preview not available in this installation"
        case .rejected(let reason): return "Rejected: \(reason)"
        case .httpStatus(let code): return code == 404 ? "Not found (HTTP 404)" : "HTTP \(code)"
        case .failed: return "Failed (offline or timed out)"
        }
    }
}

/// Preferences card: choose Production or Staging, see what the active source holds, refresh, and
/// return to Production. Production is the default; staging is styled as a warning so a lingering
/// staging selection is impossible to miss (same convention as the Developer Pro Override).
/// Renders nothing unless the installation is eligible for the preview.
struct GearCatalogSourceDeveloperCard: View {
    @ObservedObject private var store = GearCatalogStore.shared
    @State private var isRefreshing = false
    @State private var fixtureMessage: String?

    private var isStaging: Bool { store.activeSource != .production }

    var body: some View {
        if store.previewEligibility == .eligible {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Recommended Gear Catalog",
                subtitle: "TestFlight and developer builds only. App Store installs always use Production."
            )

            if isStaging {
                Label("STAGING CATALOG ACTIVE", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.warningRed)
                Text("Recommended Gear and More show the staging catalog only. Production and bundled partners are hidden until you return to Production.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.warningRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Catalog source", selection: Binding(
                get: { store.activeSource },
                set: { select($0) }
            )) {
                ForEach(GearCatalogSource.allCases, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                row("Source", store.activeSource.displayName)
                row("Content", store.activePublicationSummary)
                row("Visible cards", "\(store.content.pages.count)")
                row("Last refresh", isRefreshing ? "Refreshing…" : (store.lastRefreshOutcome?.developerDescription ?? "—"))
            }

            HStack(spacing: 10) {
                Button("Refresh Now") {
                    run { await store.refresh(force: true) }
                }
                .disabled(isRefreshing)

                if isStaging {
                    Spacer()
                    Button("Return to Production") { select(.production) }
                        .foregroundStyle(AppTheme.Colors.warningRed)
                }
            }
            .font(.subheadline.weight(.semibold))

            if isStaging {
                // Fixture testing without a bucket: copy a document from docs/remote-gear/fixtures
                // (the Simulator shares the Mac clipboard) and load it. Same validation and ordering
                // as a download; production is never affected.
                HStack(spacing: 10) {
                    Button("Load Fixture from Clipboard", action: loadFixtureFromClipboard)
                    Spacer()
                    Button("Reset Staging Data") {
                        fixtureMessage = store.resetStagingData()
                            ? "Staging data cleared."
                            : GearCatalogStore.RefreshOutcome.previewUnavailable.developerDescription
                    }
                    .foregroundStyle(AppTheme.Colors.warningRed)
                }
                .font(.caption.weight(.semibold))

                if let fixtureMessage {
                    Text(fixtureMessage)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isStaging ? AppTheme.Colors.warningRed.opacity(0.6) : AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func loadFixtureFromClipboard() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string, let data = text.data(using: .utf8) else {
            fixtureMessage = "The clipboard has no text."
            return
        }
        do {
            let changed = try store.acceptStagingFixture(data)
            fixtureMessage = changed ? "Fixture applied: \(store.activePublicationSummary)" : "Fixture identical to the current staging publication."
        } catch {
            fixtureMessage = "Fixture rejected: \(error)"
        }
        #endif
    }

    private func select(_ source: GearCatalogSource) {
        fixtureMessage = nil
        guard source != store.activeSource else { return }
        AppHaptics.selection()
        run { await store.selectSourceAndRefresh(source) }
    }

    private func run(_ operation: @escaping () async -> GearCatalogStore.RefreshOutcome) {
        isRefreshing = true
        Task {
            _ = await operation()
            isRefreshing = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown at the top of Recommended Gear and More while the staging catalog is selected, so
/// screenshots and testers can never mistake staging content for production.
struct GearStagingCatalogBanner: View {
    @ObservedObject private var store = GearCatalogStore.shared

    var body: some View {
        if store.activeSource != .production {
            Label("STAGING CATALOG · Test preview", systemImage: "flask.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.warningRed)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.Colors.warningRed.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.Colors.warningRed.opacity(0.5), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Staging catalog. Test preview.")
        }
    }
}
