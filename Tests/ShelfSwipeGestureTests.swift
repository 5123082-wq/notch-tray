// Pure intent sequences: no system input, user folders, or graphical session.
import Foundation

@main
struct ShelfSwipeGestureTests {
    static func main() {
        var gesture = ShelfSwipeGesture()
        var time = 0.0
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            checks += 1
            print("PASS: \(description)")
        }
        func feed(_ x: Double = 0, _ y: Double = 0, _ phase: ShelfSwipeGesture.Phase = .changed,
                  momentum: Bool = false, precise: Bool = true, gap: Double = 0.016) -> ShelfSwipeGesture.Decision {
            time += gap
            return gesture.consume(deltaX: x, deltaY: y, phase: phase,
                                   isMomentum: momentum, isPrecise: precise, timestamp: time)
        }

        let begin = feed(0, 3, .began)
        check(begin.route == .pending && begin.began && !begin.didResolve,
              "small initial vertical movement is buffered without assigning an axis")
        check(feed(-8, 1).route == .pending,
              "first horizontal movement remains undecided until hysteresis is crossed")
        let horizontal = feed(-18, 1)
        check(horizontal.route == .horizontal && horizontal.didResolve,
              "horizontal intention wins after an initial vertical wobble")
        check(horizontal.displacementX == -26 && horizontal.displacementY == 5,
              "resolution preserves the complete net movement for interactive tracking")
        let continued = feed(-100, 15)
        check(continued.route == .horizontal && !continued.didResolve,
              "resolved horizontal movement remains with the same owner")
        check(feed(300, 0).route == .horizontal,
              "finger reversal changes displacement without reassigning the axis")
        let horizontalEnd = feed(900, 900, .ended)
        check(horizontalEnd.route == .horizontal && horizontalEnd.ended && !horizontalEnd.cancelled,
              "physical ending reports the horizontal owner")
        check(horizontalEnd.displacementX == 174 && horizontalEnd.displacementY == 20,
              "terminal deltas cannot add fictional movement")
        let horizontalInertia = feed(0, 90, .began, momentum: true)
        check(horizontalInertia.route == .horizontal && !horizontalInertia.didResolve && !horizontalInertia.began,
              "momentum inherits horizontal intent despite vertical noise and a began marker")

        check(feed(3, 0, .began).route == .pending,
              "new physical contact clears the previous horizontal owner")
        check(feed(1, -8).route == .pending,
              "the inverse initial horizontal wobble is also buffered")
        let vertical = feed(1, -18)
        check(vertical.route == .vertical && vertical.didResolve,
              "vertical intention wins by the same rule after horizontal wobble")
        check(feed(100, -2).route == .vertical,
              "a resolved vertical stream cannot accidentally become paging")
        let verticalEnd = feed(0, 0, .ended)
        check(verticalEnd.route == .vertical && verticalEnd.ended,
              "vertical owner receives its physical ending")
        check(feed(90, 0, .none, momentum: true).route == .vertical,
              "vertical momentum remains native even when its tail drifts horizontally")

        check(feed(8, 8, .began).route == .pending,
              "balanced initial diagonal movement does not favor vertical")
        check(feed(18, 18).route == .pending,
              "passing the old 24-point diagonal cutoff does not force an axis")
        let resolvedDiagonal = feed(14, 0)
        check(resolvedDiagonal.route == .horizontal && resolvedDiagonal.didResolve,
              "a diagonal beginning can become clearly horizontal without lifting fingers")
        _ = feed(0, 0, .ended)
        _ = feed(8, 8, .began)
        _ = feed(18, 18)
        check(feed(0, 14).route == .vertical,
              "the same diagonal beginning can become clearly vertical")
        _ = feed(0, 0, .ended)

        _ = feed(0, 5, .began)
        _ = feed(-4, -5)
        _ = feed(-4, 5)
        let wobble = feed(-4, -5)
        check(wobble.route == .horizontal && wobble.displacementY == 0,
              "opposing vertical jitter cancels instead of accumulating into a false vertical lock")
        _ = feed(0, 0, .ended)
        check(feed(12, 0, .began).route == .horizontal,
              "clear first movement can resolve immediately without a mandatory extra event")
        _ = feed(0, 0, .ended)
        check(feed(0, -12, .began).route == .vertical,
              "clear vertical movement has exactly the same response threshold")
        _ = feed(0, 0, .ended)

        _ = feed(-5, 2, .began)
        let shortEnd = feed(-100, 0, .ended)
        check(shortEnd.route == .pending && shortEnd.ended && !shortEnd.didResolve,
              "a short unresolved contact ends without inventing intent")
        check(feed(-100, 0, .none, momentum: true).route == .ignore,
              "inertia cannot resolve a short ambiguous contact")
        _ = feed(-15, 0, .began)
        let cancelled = feed(100, 0, .cancelled)
        check(cancelled.route == .horizontal && cancelled.cancelled && cancelled.ended,
              "cancellation identifies the current owner for its cleanup")
        check(feed(-100, 0).route == .ignore,
              "changed events cannot restart a cancelled gesture")
        check(feed(-100, 0, .none, momentum: true).route == .ignore,
              "cancelled gestures cannot claim a momentum tail")

        check(feed(-100, 0, .began, precise: false).route == .ignore,
              "ordinary mouse-wheel input passes through without arbitration")
        check(feed(-100, 0, .none).route == .ignore,
              "unphased precise-wheel input also stays native")
        check(feed(0, 0, .mayBegin).route == .ignore,
              "pre-contact events contain no directional intention")
        check(feed(-15, 0, .changed).route == .ignore,
              "a changed event without actual contact beginning cannot arm paging")
        _ = feed(-15, 0, .began)
        gesture.reset()
        check(feed(-100, 0).route == .ignore,
              "interaction guard reset discards the active contact")
        check(feed(-100, 0, .none, momentum: true).route == .ignore,
              "reset also releases momentum ownership")
        check(feed(-15, 0, .began).route == .horizontal,
              "fresh contact after reset still responds")
        _ = feed(0, 0, .ended)
        check(feed(0, 0, .none, momentum: true, gap: 1).route == .ignore,
              "unrelated late momentum cannot inherit old horizontal intent")

        check(feed(Double.nan, 0, .began).route == .ignore,
              "invalid movement cannot arm a gesture")
        _ = feed(0, -15, .began)
        check(gesture.consume(deltaX: 0, deltaY: 5, phase: .changed, isMomentum: false,
                              isPrecise: true, timestamp: time - 1).route == .ignore,
              "nonmonotonic event time safely resets the old stream")
        check(feed(0, 0, .stationary).route == .ignore,
              "stationary events cannot revive an invalidated contact")

        print("Shelf swipe axis checks passed: \(checks).")
    }
}
