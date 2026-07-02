# 2.2.1 Trip Planner Polish Plan

Status: plan only — no Trip Planner code changes were made in the 2.2.1 pump/E85 pass.

## Files inspected

- `TripPlannerView.swift` (map rendering, stop cards, fuel plan card, target-fuel chips, gas-only planner)
- `RouteE85Planner.swift` (corridor analysis, stop recommendation, reserve math, risk)
- `SavedTripStore.swift`, `StationReportStore.swift` (context only)

## Findings that drive the plan

1. **Recommended stop "not appearing" on map.** The recommended E85 stop is actually *in* the pin set — `mapStations` (TripPlannerView.swift:192–206) protects recommended-stop IDs before applying the 20-pin cap — but the map content builder (inline map :862–870, full map ~:3728–3759) draws it with the same yellow `fuelpump.circle.fill` as every other E85 station. Gas-Only stops already get a distinct orange pin (:872–880). So the stop is invisible-by-indistinguishability, not dropped. Also: backup gas pins are intentionally omitted from the inline map (:881–884), which can look like "my stop is missing" when the recommendation is a gas backup.
2. **Gas Only target fuel** (sentinel `gasolineOnlyBlend = 0.0`, :28; `isGasolineOnly`, :103) already fully bypasses E85 discovery (`planRoute` branches at :2624–2632 into `discoverGasOnlyStations` → `computeGasOnlyPlan` :2816–2944). Behavior is mostly correct; what needs polish is definition and messaging (see below), plus the chip is only offered for flex-fuel vehicles (:106–110) — decide whether non-flex vehicles should default into this mode instead of hiding it.
3. **Arrival reserve is a single point estimate.** Computed as `destReserveFraction` (RouteE85Planner.swift:642–643, no-stop variant :521) and `gasOnlyDestinationReserveFraction` (TripPlannerView.swift:2835/:2865/:2918/:2922). Displayed as exact values: "Estimated arrival buffer" row (:1008–1012 via `arrivalReserveText` :1120–1133), "Arrive with about X% buffer · approx. Y gal" (:2086–2093), per-stop "About X% buffer …" (:2096–2103).
4. **Distance to next stop is missing from stop cards.** Cards show only "Along route" / "Off route" absolutes (:1712/:1731, :1962/:1980, :1549/:1554). Leg distance ("Drive X mi to Stop N") exists only inside the Fuel Plan card via `addLeg` (:2078–2083). All data needed (`distanceAlongRouteMiles`) already exists — this is presentation-only.
5. **Map usability.** Inline map is `Map(..., interactionModes: [])` (:853) deliberately, so it can't fight the parent `ScrollView` (:249); pinch/pan lives only in `FullRouteMapView` (:3720). There are load-order workarounds for an iOS 27 MapKit Metal/MSAA crash (:846, :2608–2621) — do not restructure map insertion casually.
6. **Small logic wart:** `recommendedForReserveTarget` is set plan-wide (RouteE85Planner.swift:674–683), so when the outcome is `reserveStopRecommended` *every* stop card shows "Recommended to meet your arrival buffer" (:1696–1706), even required stops.

## Proposed changes (implementation order)

| # | Change | Where | Risk |
|---|--------|-------|------|
| 1 | Distinct pin for the recommended E85 stop: green badge/`star.circle.fill`-style Annotation when station ID ∈ `recommendedStops`, on both inline and full maps | TripPlannerView.swift :862–870, full map annotations ~:3728 | Low (pure rendering; mind the iOS 27 map workarounds — don't change map insertion, only annotation content) |
| 2 | "Next stop in X mi / arrive with ~Y%" line on each stop card, reusing the `addLeg` delta math (`stop.distanceAlongRouteMiles - prevMiles`) | `recommendedStopCard` :1659, `gasOnlyStopCard` :1926 | Low (data already computed) |
| 3 | Arrival reserve as a range: wrap the point estimate in ±5% (or ±0.5 gal) band → "Estimated arrival fuel: 45–55%", "About 24–31% buffer on arrival"; keep "Unreachable" path | `arrivalReserveText` :1120–1133, `arrivalLine`/`stopArrivalLine` :2086–2103, stop-card buffer metrics :1717/:1967 | Low–medium (string/format only, but touches several call sites; clamp band to 0–100 and keep low-buffer warnings keyed off the *lower* bound) |
| 4 | Fix per-stop `recommendedForReserveTarget` so only the stop(s) actually added for the reserve target carry the "meet your arrival buffer" label | RouteE85Planner.swift :674–683 | Medium (planner logic; cover with the on-disk test file pattern) |
| 5 | Gas Only clarity: subtitle under the chip ("Route planned with regular gas stations only — no E85 required"), show backup-gas pins or an explicit "pins on full map" hint on the inline map; decide default for non-flex vehicles | TripPlannerView.swift :437–449, :881–884 | Medium (UX decision needed from Julian on the non-flex default) |

Suggested order: 1 → 2 → 3 (all presentation, one TestFlight build), then 4 → 5 in a follow-up once verified.

## Smoke tests on iPhone (simulator + real device)

- Plan an E85 route with >20 corridor stations: recommended stop pin is visibly distinct on inline + full map, survives the 20-pin cap, and matches the stop card.
- Gas Only route (flex-fuel vehicle): orange stops render, no E85 sections appear, chip messaging reads correctly.
- Stop cards: "Next stop in X mi" matches the Fuel Plan card leg distances for stop 1, stop 2, and destination.
- Arrival range wording on: comfortable route, tight route (low reserve), and unreachable route ("Unreachable" must still show, not a nonsense range like "-5–5%").
- Map interaction: inline map still scrolls with the page (no gesture capture), full map pinch/pan/zoom works, and no Metal/MapKit crash on plan → replan → back-navigation (the iOS 27 crash workaround area).
- Real device only: replan while driving/moving to confirm camera and pins stay stable.
