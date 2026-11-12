# 85Blends — Claude Code Guide

Project quick facts:

- **Xcode project:** `EightyFiveBlends.xcodeproj` (no `.xcworkspace`; open the `.xcodeproj` directly)
- **App target / product name:** `EightyFiveBlends` (Bundle ID `com.e85blends.app.ios`)
- **Internal configuration (retired for distribution):** the `EightyFiveBlends Internal` scheme and `Internal` configuration (Bundle ID `com.e85blends.app.ios.internal`) still exist on the same `EightyFiveBlends` PBX native target, but the separate **85Blends Internal** App Store Connect app is retired. Testers use the normal app through TestFlight. Don't recreate the Internal app or ask for its App Store Connect setup.
- **Schemes (shared):** `EightyFiveBlends`, `EightyFiveBlends Internal`
- **iOS deployment target:** 17.6 (App Store), 26.4 (Internal)
- **Xcode Cloud config:** present at `EightyFiveBlends.xcodeproj/xcshareddata/xcodecloud/manifest.json` (workflow ID `7dd08a73-3551-4068-8509-7fe8d370bf4d`, workflow target label `85Blends`). Start conditions are configured in App Store Connect; this repo does **not** hold them, so never assume a push starts a build. See **Xcode Cloud Workflows** below.
- **Tests:** unit-test target `EightyFiveBlendsTests` (sources in the synced folder `EightyFiveBlends.xcodeproj/EightyFiveBlendsTests/`, hosted by the app) is a Testable in both shared schemes, so `xcodebuild test` runs it. Swift Testing (`import Testing`, `@Test`) is used in nearly every test file; XCTest is used only in `NativeAdTextLayoutTests.swift` and `NearbyE85RenderingTests.swift`.

## Default Rule: Claude Never Archives or Uploads

- **Testing uses the normal app through TestFlight.** Beta builds are the production-bundle 85Blends app (`com.e85blends.app.ios`, `EightyFiveBlends` scheme, `Release` configuration) delivered to TestFlight by the Xcode Cloud **Default** workflow, which Julian runs. Claude does not start distribution builds.
- **Never archive or upload** anything yourself unless Julian explicitly says **"prepare production release."** A merged fix, a green build, or an urgent-sounding bug is not permission; the exact phrase is.
- TestFlight builds are Release builds: neither `DEBUG` nor `INTERNAL_BUILD` is set. Tester-only behavior in them must be a runtime check scoped to that feature (for example `GearCatalogPreviewEligibility`, from StoreKit's verified `AppTransaction` environment), never a globally enabled compiler flag.
- Simulator smoke builds of either scheme are always fine — the rule is about archiving and uploading.

## Product Policy: Cloud Sync Is Free, Not Pro

CloudKit/SwiftData sync is a **core 85Blends capability available to every user, Free and Pro** — not a Pro subscription benefit. This was verified end-to-end (code, entitlements, and real-device testing) by the 2.3.0 CloudKit/SwiftData audit: `EightyFiveBlendsApp.swift` configures `cloudKitDatabase: .automatic` unconditionally, with no reference to `isPro`/`isProUser` anywhere in the `ModelContainer` construction path. Keep it that way:

- Never gate the `ModelContainer`, CloudKit initialization, or CloudKit import/export behind `isPro`/`isProUser` or any other subscription check.
- Never advertise Cloud Sync as a Pro/Premium benefit in paywall, onboarding, or marketing copy, and never add it to the Pro feature list.
- Never create separate Free/Pro persistence containers or a parallel Cloud Sync entitlement abstraction.
- Pro stays scoped to actual premium functionality (Trip Planning, route-based fuel stops, advanced tools/limits/analytics/alerts) — not to whether a user's data syncs.

## Xcode Cloud Workflows

Workflows and their start conditions live in App Store Connect, not this repo. Only what has been observed is recorded here; don't infer other trigger rules or settings.

| Workflow | What is known |
|---|---|
| **Default** | Archives the normal app (`EightyFiveBlends` scheme, `Release`, `com.e85blends.app.ios`) and delivers it to TestFlight. Build 293 archived and completed TestFlight delivery from `main` commit `0955482`. This is the path to TestFlight. |
| **85Blends Internal** | Manual start, test-only: no Archive action and no post-actions, so it delivers nothing. |

Configuration notes (from the project file): `PRODUCT_BUNDLE_IDENTIFIER` is set **per configuration** on the single `EightyFiveBlends` target (`Internal` → `.internal`, `Debug`/`Release` → production), and each shared scheme pins its Archive action to one configuration.

Guardrails:

- Don't edit workflows. If one looks wrong, stop and tell Julian.
- Never pass `-configuration` to `xcodebuild archive` to override a scheme's pinned archive configuration — that is the one local path that could mismatch scheme and bundle ID.
- Internal build numbers (`CURRENT_PROJECT_VERSION` in the `Internal` configuration) are bumped independently of Debug/Release; bumping Internal must not touch the other two.

## Mobile Bug Fix Workflow

Follow this exact loop for a small bug fix pushed via Xcode Cloud → TestFlight. Keep changes surgical.

### 1. Create a fix branch

Always branch from the current `origin/main` (`main` is the primary branch), never from a stale local branch:

```sh
git fetch origin
git checkout -b fix/<short-slug> origin/main
```

Naming: `fix/<area>-<one-word>` (e.g. `fix/trip-planner-crash`, `fix/pump-partial-fill-warning`). For a true hotfix off `main`, use `hotfix/<version>-<slug>`.

### 2. Make a small targeted fix

- Edit the smallest set of files that resolves the reported symptom. No drive-by refactors, no comment cleanup, no formatter sweeps.
- Do not touch `SubscriptionManager.swift`, StoreKit config, entitlements, `Info.plist`, or bundle identifiers unless the bug is specifically there — those are App Review land mines.
- Preserve existing indentation style (tabs vs spaces) as-is per file.
- If the fix would grow past ~50 changed lines or touches more than 2–3 files, **stop and ask** (see §6).

### 3. Run this before pushing

The smoke check is a build against the simulator SDK:

```sh
xcodebuild \
  -project EightyFiveBlends.xcodeproj \
  -scheme EightyFiveBlends \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build | tail -40
```

The `| tail -40` keeps the terminal output short — the important signal is the last few lines (`BUILD SUCCEEDED` or the first error). If it fails, fix the error before pushing.

The `EightyFiveBlendsTests` target is wired into both shared schemes, so also run the tests for the area you changed. `test` needs a concrete simulator destination (list the installed ones with `xcrun simctl list devices available`):

```sh
xcodebuild \
  -project EightyFiveBlends.xcodeproj \
  -scheme EightyFiveBlends \
  -destination 'platform=iOS Simulator,name=<installed iPhone simulator>' \
  test | tail -40
```

If the fix touches `BlendCalculator.swift` or math logic, make sure `BlendCalculatorTests` is among the tests you ran and mention it in the commit message.

### 4. Commit

Small, single-purpose commit. Reuse the repo's existing style (imperative mood, short subject, no scope prefix):

```sh
git add <specific files>
git commit -m "Fix <symptom> in <area>"
```

Do **not** use `git add -A` or `git add .` — `Website Heros/` and various local `sim_*.png` screenshots live in the tree and are ignored on purpose. Add files by name.

### 5. Push to trigger Xcode Cloud

```sh
git push -u origin fix/<short-slug>
```

Don't assume the push starts Xcode Cloud: start conditions are set in App Store Connect and aren't recorded here. The known path to TestFlight is a PR from the fix branch into `main`, merged with Julian's approval, then the **Default** workflow building that `main` commit (as with Build 293).

Never `git push --force` to `main` or a release branch. Force-push only your own fix branch, and only when you understand why.

### 6. When to stop and ask instead of guessing

Pause and ask Julian before proceeding if any of these are true:

- The fix would touch **StoreKit / SubscriptionManager / entitlements / Pro gating / Info.plist / bundle IDs / signing** — App Review–sensitive surfaces.
- The repro steps aren't clear, or you can't reproduce the bug from the description.
- The fix requires a schema change, a Supabase migration, or a new API key.
- The change would land on `main` directly, or would need a force-push anywhere.
- The change is larger than a single-file, ~50-line surgical edit.
- Xcode Cloud is failing for a reason that isn't obvious from the last few log lines (do not start flipping build settings to make it green).
- You are about to bump the version/build number or edit release notes.
- Anything in `docs/KNOWN_ISSUES.md` or `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md` looks like it might apply — surface it, don't silently work around it.

Default posture: when in doubt, ask. A 30-second question beats an unwanted TestFlight build.
