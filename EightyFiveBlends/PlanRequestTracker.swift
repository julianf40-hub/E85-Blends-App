//
//  PlanRequestTracker.swift
//  EightyFiveBlends
//
//  Pure, SwiftUI-independent request-generation and plan-staleness tracking for Trip
//  Planner. Task cancellation is cooperative — a superseded async task can still be
//  mid-flight when a newer request starts — so this generation counter, not
//  `Task.isCancelled` alone, is what guarantees an old request's result can never
//  overwrite a newer one.
//

import Foundation

struct PlanRequestTracker {
    /// The generation identifying the current/latest planning request. A request should
    /// only write its result if the generation it captured when it started still matches
    /// this value.
    private(set) var currentGeneration = 0

    /// True once a route-affecting input has changed since a plan was last generated.
    private(set) var isPlanStale = false

    init() {}

    /// Starts a new planning attempt: advances the generation (so any older request's
    /// pending writes stop applying, even ones that already passed a cancellation check)
    /// and clears the stale flag, since this attempt is meant to reflect the current
    /// inputs. Returns the new generation for the caller to tag the async work it's about
    /// to start.
    @discardableResult
    mutating func beginNewAttempt() -> Int {
        currentGeneration += 1
        isPlanStale = false
        return currentGeneration
    }

    /// Advances the generation without resetting the stale flag — used when superseding
    /// in-flight work without starting a new attempt of its own (e.g. leaving the screen).
    @discardableResult
    mutating func supersedeInFlightWork() -> Int {
        currentGeneration += 1
        return currentGeneration
    }

    /// True if a result/state write captured under `generation` is still allowed to apply —
    /// i.e. no newer attempt has begun since.
    func isCurrent(_ generation: Int) -> Bool {
        generation == currentGeneration
    }

    /// Marks the existing plan as stale because a route-affecting input changed. A no-op
    /// when `hasPlan` is false, so the stale warning never appears before a plan has ever
    /// been generated.
    mutating func invalidate(hasPlan: Bool) {
        guard hasPlan else { return }
        isPlanStale = true
    }
}
