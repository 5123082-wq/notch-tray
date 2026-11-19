import Foundation

@main
struct MotionTests {
    static func main() {
        var spring = TrayMotion()
        precondition(TrayMotion.surfaceOpacity(at: 0) == 0)
        precondition(TrayMotion.contentOpacity(at: 0) == 0)
        spring.retarget(open: true)
        for _ in 0..<10 { spring.advance(seconds: 1.0 / 120) }
        let position = spring.value
        let velocity = spring.velocity
        spring.retarget(open: false)
        precondition(spring.value == position && spring.velocity == velocity, "Reversing must preserve both position and velocity")
        spring.advance(seconds: 1.0 / 120)
        precondition(abs(spring.value - position) < 0.1, "No discontinuity on reversal")
        for _ in 0..<120 { spring.advance(seconds: 1.0 / 120) }
        precondition(spring.settled)
        spring.finish()
        precondition(spring.value == 0 && spring.velocity == 0)
        var endpoints: [Double] = []
        for rate in [30, 60, 120] {
            var motion = TrayMotion()
            motion.retarget(open: true)
            for _ in 0..<rate / 3 { motion.advance(seconds: 1.0 / Double(rate)) }
            endpoints.append(motion.value)
        }
        precondition((endpoints.max()! - endpoints.min()!) < 0.000001, "Motion should not depend on display refresh rate")
        precondition(TrayMotion.contentOpacity(at: 1) == 1)
        precondition(TrayMotion.surfaceOpacity(at: 1) == 1)
        print("Motion checks passed: transparent idle, continuous reversal, settled idle, 30/60/120 Hz consistency.")
    }
}
