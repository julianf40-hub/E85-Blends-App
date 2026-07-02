# 85Blends — Claude Code Guide

Project quick facts:

- **Xcode project:** `EightyFiveBlends.xcodeproj` (no `.xcworkspace`; open the `.xcodeproj` directly)
- **App target / product name:** `EightyFiveBlends` (Bundle ID `com.e85blends.app.ios`)
- **Internal target:** shares the same `EightyFiveBlends` PBX native target with the `EightyFiveBlends Internal` scheme (Bundle ID `com.e85blends.app.ios.internal`)
- **Schemes (shared):** `EightyFiveBlends`, `EightyFiveBlends Internal`
- **iOS deployment target:** 17.6 (App Store), 26.4 (Internal)
- **Xcode Cloud config:** present at `EightyFiveBlends.xcodeproj/xcshareddata/xcodecloud/manifest.json` (workflow ID `7dd08a73-3551-4068-8509-7fe8d370bf4d`, workflow target label `85Blends`). Xcode Cloud triggers off pushes to the branch(es) configured in App Store Connect — this repo does **not** hold the trigger rules. See **Xcode Cloud Workflows** below for the Internal vs Production split.
- **Tests:** `EightyFiveBlends.xcodeproj/EightyFiveBlendsTests/BlendCalculatorTests.swift` exists on disk but there is **no** test target in the pbxproj and no testable reference in either scheme. `xcodebuild test` will not run these until a test target is added. Do not assume tests exist — treat this repo as build-only until the test target is wired up.

## Default Rule: Internal Builds Only

- **Claude's default workflow is Internal only.** Every beta update, fix, hotfix, or TestFlight validation build goes to the **85Blends Internal** App Store Connect app (`com.e85blends.app.ios.internal`) via the `EightyFiveBlends Internal` scheme and `Internal` configuration.
- **Never archive or upload production** — the `EightyFiveBlends` scheme, `Release` configuration, or `com.e85blends.app.ios` — unless Julian explicitly says **"prepare production release."** A merged fix, a green build, or an urgent-sounding bug is not permission; the exact phrase is.
- Simulator smoke builds of either scheme are always fine — the rule is about archiving and uploading.

## Xcode Cloud Workflows

Two separate workflows in App Store Connect keep Internal and Production builds from crossing over. The trigger/branch rules live in ASC, not this repo — this table is the source of truth for what each workflow must be set to.

| Setting | 85Blends Internal | 85Blends Production |
|---|---|---|
| Workflow name | `85Blends Internal` | `85Blends Production` |
| Scheme (Archive action) | `EightyFiveBlends Internal` | `EightyFiveBlends` |
| Archive configuration | `Internal` (pinned by the scheme) | `Release` (pinned by the scheme) |
| Bundle ID produced | `com.e85blends.app.ios.internal` | `com.e85blends.app.ios` |
| Uploads to (ASC app) | 85Blends Internal | 85Blends (production) |
| TestFlight destination | Internal Testing | External / App Store release candidates |
| Start condition | Branch changes: `internal/beta`, `claude/*`, `fix/*`, `feature/*` | `main` only — prefer **manual start** |
| Purpose | Beta updates, fixes, hotfixes, TestFlight validation | Public App Store / release candidates only |

Why the bundle IDs can't cross over: both configs live on the single `EightyFiveBlends` target, and `PRODUCT_BUNDLE_IDENTIFIER` is set **per configuration** (`Internal` → `.internal`, `Debug`/`Release` → production). Each shared scheme pins its Archive action to one configuration, so archiving the Internal scheme can only ever produce the internal bundle ID, and archiving the main scheme can only produce the production one.

Guardrails:

- The `85Blends Internal` workflow must never reference the `EightyFiveBlends` scheme, and `85Blends Production` must never reference `EightyFiveBlends Internal`. If a workflow shows the wrong scheme, stop and tell Julian — don't "fix" it by editing the workflow yourself.
- Never pass `-configuration` to `xcodebuild archive` to override a scheme's pinned archive configuration — that is the one local path that could mismatch scheme and bundle ID.
- Internal build numbers (`CURRENT_PROJECT_VERSION` in the `Internal` configuration) are bumped independently of Debug/Release; bumping Internal must not touch the other two.

## Mobile Bug Fix Workflow

Follow this exact loop for a small bug fix pushed via Xcode Cloud → TestFlight. Keep changes surgical.

### 1. Create a fix branch

Always branch from the current release/working branch (usually `trip-planner-v2.2` or whatever main is at the time), never from a stale local branch:

```sh
git fetch origin
git checkout -b fix/<short-slug> origin/<base-branch>
```

Naming: `fix/<area>-<one-word>` (e.g. `fix/trip-planner-crash`, `fix/pump-partial-fill-warning`). For a true hotfix off `main`, use `hotfix/<version>-<slug>`.

### 2. Make a small targeted fix

- Edit the smallest set of files that resolves the reported symptom. No drive-by refactors, no comment cleanup, no formatter sweeps.
- Do not touch `SubscriptionManager.swift`, StoreKit config, entitlements, `Info.plist`, or bundle identifiers unless the bug is specifically there — those are App Review land mines.
- Preserve existing indentation style (tabs vs spaces) as-is per file.
- If the fix would grow past ~50 changed lines or touches more than 2–3 files, **stop and ask** (see §6).

### 3. Run this before pushing

There is no wired test target, so the smoke check is a build against the simulator SDK:

```sh
xcodebuild \
  -project EightyFiveBlends.xcodeproj \
  -scheme EightyFiveBlends \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build | tail -40
```

The `| tail -40` keeps the terminal output short — the important signal is the last few lines (`BUILD SUCCEEDED` or the first error). If it fails, fix the error before pushing.

If the fix touches `BlendCalculator.swift` or math logic, mention it in the commit message so a human knows to run the on-disk unit tests locally in Xcode until they are wired into the scheme.

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

Xcode Cloud picks up the push based on the workflow's branch rules in App Store Connect. To reach TestFlight the push usually needs to land on the branch the workflow watches (commonly the release branch, not the fix branch) — open a PR from the fix branch into that base, merge, and Xcode Cloud will build and upload to TestFlight from the merge commit.

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
