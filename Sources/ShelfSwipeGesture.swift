// Notch Tray — GPL-3.0.
import Foundation

/// Chooses a scroll axis, not a page. The view holds undecided events until the
/// user's direction is clear, then hands the entire stream to that one owner.
/// Deltas already reflect the macOS scrolling preference.
struct ShelfSwipeGesture {
    enum Phase { case none, mayBegin, began, changed, stationary, ended, cancelled }
    enum Route { case pending, horizontal, vertical, ignore }

    struct Decision: Equatable {
        let route: Route
        let didResolve: Bool
        let began: Bool
        let ended: Bool
        let cancelled: Bool
        let displacementX: Double
        let displacementY: Double

        static let ignore = Decision(route: .ignore, didResolve: false, began: false,
                                     ended: false, cancelled: false,
                                     displacementX: 0, displacementY: 0)
    }

    private var route: Route = .pending
    private var touching = false
    private var displacementX = 0.0
    private var displacementY = 0.0
    private var lastTimestamp: TimeInterval?

    mutating func reset() { self = ShelfSwipeGesture() }

    mutating func consume(deltaX: Double, deltaY: Double, phase: Phase,
                          isMomentum: Bool, isPrecise: Bool,
                          timestamp: TimeInterval) -> Decision {
        guard isPrecise, deltaX.isFinite, deltaY.isFinite, timestamp.isFinite else {
            reset()
            return .ignore
        }

        // Inertia inherits an already resolved axis. It cannot decide intent or
        // turn an ambiguous, cancelled, or unrelated scroll into a page swipe.
        if isMomentum {
            guard route == .horizontal || route == .vertical,
                  let previous = lastTimestamp, timestamp >= previous,
                  timestamp - previous < 0.6 else {
                reset()
                return .ignore
            }
            lastTimestamp = timestamp
            return decision()
        }

        switch phase {
        case .none, .mayBegin:
            // Unphased wheel input stays native. Actual trackpad contact starts
            // at .began; a pre-contact event contains no directional intent.
            reset()
            return .ignore
        case .began:
            reset()
            touching = true
        case .changed, .stationary, .ended, .cancelled:
            guard touching else { return .ignore }
        }

        if let previous = lastTimestamp, timestamp < previous {
            reset()
            return .ignore
        }
        lastTimestamp = timestamp

        if phase == .ended || phase == .cancelled {
            let result = decision(ended: true, cancelled: phase == .cancelled)
            touching = false
            // Keep a completed axis for its momentum tail, but never keep a
            // cancelled contact. Terminal deltas are not fresh gesture input.
            if phase == .cancelled { reset() }
            return result
        }

        displacementX += deltaX
        displacementY += deltaY
        let previousRoute = route
        if route == .pending {
            let x = abs(displacementX)
            let y = abs(displacementY)
            // Symmetric hysteresis: a few points of initial Y jitter cannot
            // steal a horizontal gesture (and the inverse is equally true).
            // Net movement cancels wobble; summing absolute travel does not.
            if x >= 12, x >= y * 1.25 { route = .horizontal }
            else if y >= 12, y >= x * 1.25 { route = .vertical }
            // An ambiguous diagonal remains undecided; it is never forced
            // into vertical scrolling merely because enough time/distance passed.
        }
        return decision(didResolve: previousRoute == .pending && route != .pending,
                        began: phase == .began)
    }

    private func decision(didResolve: Bool = false, began: Bool = false,
                          ended: Bool = false, cancelled: Bool = false) -> Decision {
        Decision(route: route, didResolve: didResolve, began: began, ended: ended,
                 cancelled: cancelled, displacementX: displacementX, displacementY: displacementY)
    }
}
