// Notch Tray — GPL-3.0. A continuous, critically damped reveal.
import Foundation

struct TrayMotion {
    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    private(set) var target: Double = 0
    private let frequency: Double = 24

    // Retarget without discarding either position or velocity.
    mutating func retarget(open: Bool) { target = open ? 1 : 0 }
    mutating func finish() { value = target; velocity = 0 }
    var settled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.015 }

    mutating func advance(seconds: Double) {
        let dt = max(0, seconds)
        let displacement = value - target
        let coefficient = velocity + frequency * displacement
        let decay = exp(-frequency * dt)
        value = target + (displacement + coefficient * dt) * decay
        velocity = (velocity - frequency * coefficient * dt) * decay
    }

    static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
    static func contentOpacity(at value: Double) -> Double { smoothstep((value - 0.18) / 0.66) }
    static func surfaceOpacity(at value: Double) -> Double { smoothstep(value / 0.12) }
}
