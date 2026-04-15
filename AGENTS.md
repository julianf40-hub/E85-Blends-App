# AGENTS.md

## App Context
- Expo React Native app with iOS-first priorities and TestFlight readiness.
- Primary product areas: calculator, fuel log, reminders, stations, settings, navigation tabs, and startup flow.
- Goal for edits/reviews: production-safe polish, stability, and release readiness.

## Development Rules
- Keep changes minimal, targeted, and production-safe.
- Do not add unnecessary dependencies; prefer existing libraries and patterns already in this repo.
- Avoid large refactors unless clearly required to fix a real bug/risk.
- Prefer consistency with existing architecture, naming, and UX behavior.
- Favor the smallest safe fix first, then propose follow-up improvements separately.

## Priority Review Areas
1. Navigation correctness (tabs, hidden routes, startup routing, deep-link edge cases).
2. Preferences/state consistency across screens and shared context.
3. Calculator and fuel-log correctness (totals, octane mapping, saved payload integrity).
4. Reminders reliability (scheduling/cancel flows, permission handling, due logic).
5. Expo/iOS/TestFlight risks (config validity, release-safe env usage, startup/splash behavior).
6. Performance and UI polish in high-traffic screens (stations list/map, tab transitions, re-render hot spots).

## Code Review Expectations
- Prioritize real bugs and user-impacting behavior over style-only feedback.
- Group findings by severity: Critical, High, Medium, Low.
- Include clear file references for each issue/fix (path + relevant lines when available).
- Recommend the smallest safe code-level fix first; avoid over-engineering.
- Call out assumptions and potential regressions explicitly.

## Known Risk Areas
- Startup/navigation race conditions and hidden-tab routing behavior.
- Preference persistence drift between local state and context.
- Calculator ↔ fuel-log data mapping (octane labels, gallon totals, total price correctness).
- Reminder notification lifecycle (create/edit/delete/complete/empty state sync).
- EAS/Expo config validity and iOS release safety (TestFlight-facing behavior).

## Validation
- Prefer `pnpm check` as the primary compile/type gate.
- Run targeted smoke tests for changed flows (especially calculator, fuel log, reminders, stations, startup).
- Use full lint/test runs when changes are broad; for focused fixes, validate directly affected paths first.
