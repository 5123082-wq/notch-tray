// Pure paging physics; no AppKit, system input, screenshots, or user storage.
import Foundation

@main
struct ShelfPagingMotionTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
            print("PASS: \(message)")
        }
        func close(_ first: Double, _ second: Double, tolerance: Double = 0.000001) -> Bool {
            abs(first - second) <= tolerance
        }
        func settle(_ motion: inout ShelfPagingMotion, fps: Int = 60) {
            for _ in 0..<(fps * 2) { motion.advance(seconds: 1 / Double(fps)) }
        }

        var motion = ShelfPagingMotion()
        check(motion.position == 0 && !motion.isSettling, "initial file page rests exactly at zero")
        motion.beginDrag()
        motion.drag(contentDeltaX: -60, pageWidth: 600)
        check(close(motion.position, 0.1), "page tracks fractional finger displacement directly")
        motion.drag(contentDeltaX: -60, pageWidth: 600)
        check(close(motion.position, 0.2), "successive deltas accumulate linearly inside the strip")
        motion.drag(contentDeltaX: 90, pageWidth: 600)
        check(close(motion.position, 0.05), "reversing during contact immediately moves the page back")
        motion.advance(seconds: 0.2)
        check(close(motion.position, 0.05), "a display tick cannot pull content away from the finger")
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 0)
        check(motion.targetIndex == 0 && motion.isSettling, "short slow gesture returns to the original page")
        settle(&motion)
        check(motion.position == 0 && motion.velocity == 0 && !motion.isSettling,
              "return spring rests exactly at the original page")

        motion.beginDrag()
        motion.drag(contentDeltaX: -150, pageWidth: 600)
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 0)
        check(motion.targetIndex == 1, "deliberate quarter-page movement commits the neighboring page")
        settle(&motion)
        check(motion.position == 1, "committed movement settles at Screenshots")
        motion.beginDrag()
        motion.drag(contentDeltaX: 150, pageWidth: 600)
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 1)
        check(motion.targetIndex == 0, "slow paging has symmetric thresholds in the reverse direction")
        settle(&motion)

        motion.beginDrag()
        motion.drag(contentDeltaX: -30, pageWidth: 600)
        motion.endDrag(velocityContentX: -900, pageWidth: 600, cancelled: false, originSection: 0)
        check(motion.targetIndex == 1 && close(motion.velocity, 1.5),
              "short intentional flick commits and hands release velocity to the spring")
        settle(&motion)
        motion.beginDrag()
        motion.drag(contentDeltaX: 30, pageWidth: 600)
        motion.endDrag(velocityContentX: 900, pageWidth: 600, cancelled: false, originSection: 1)
        check(motion.targetIndex == 0 && close(motion.velocity, -1.5), "reverse flick has matching behavior")
        settle(&motion)
        motion.beginDrag()
        motion.drag(contentDeltaX: -3, pageWidth: 600)
        motion.endDrag(velocityContentX: -900, pageWidth: 600, cancelled: false, originSection: 0)
        check(motion.targetIndex == 0, "a tiny noisy high-velocity sample does not page")
        settle(&motion)

        motion.beginDrag()
        motion.drag(contentDeltaX: -270, pageWidth: 600)
        motion.endDrag(velocityContentX: 900, pageWidth: 600, cancelled: false, originSection: 0)
        check(motion.targetIndex == 0, "a deliberate return flick can cancel after passing distance threshold")
        settle(&motion)
        motion.beginDrag()
        motion.drag(contentDeltaX: -400, pageWidth: 600)
        motion.endDrag(velocityContentX: -900, pageWidth: 600, cancelled: true, originSection: 0)
        check(motion.targetIndex == 0, "cancellation overrides displacement and release momentum")
        settle(&motion)

        motion.beginDrag()
        motion.drag(contentDeltaX: 120, pageWidth: 600)
        let edge = motion.position
        check(edge < 0 && edge > -0.2, "outward edge movement is progressively resisted")
        motion.drag(contentDeltaX: -120, pageWidth: 600)
        check(close(motion.position, 0), "edge rubber-banding does not compound across delta updates")
        motion.drag(contentDeltaX: 120, pageWidth: 600)
        motion.beginDrag()
        check(close(motion.position, edge), "regrabbing elastic content preserves its presentation")
        motion.drag(contentDeltaX: 0, pageWidth: 600)
        check(close(motion.position, edge), "first zero-delta regrab frame cannot jump at an edge")
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 0)
        settle(&motion)
        check(motion.position == 0, "outward drag returns to the boundary and never wraps")
        motion = ShelfPagingMotion(index: 1)
        motion.beginDrag()
        motion.drag(contentDeltaX: -120, pageWidth: 600)
        check(close(motion.position, 1 - edge), "both outer boundaries apply identical resistance")
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 1)
        settle(&motion)
        check(motion.position == 1, "right outer edge returns to Screenshots without wrapping")

        motion = ShelfPagingMotion()
        motion.retarget(index: 1)
        motion.advance(seconds: 0.025)
        let partial = motion.position
        check(partial > 0 && partial < 1, "button transition exposes a fractional presented page")
        motion.beginDrag()
        check(close(motion.position, partial) && !motion.isSettling,
              "gesture can interrupt a settling page without jumping to its target")
        motion.drag(contentDeltaX: 30, pageWidth: 600)
        check(close(motion.position, partial - 0.05), "interrupted animation follows new finger motion immediately")
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: true, originSection: 0)
        settle(&motion)
        motion.retarget(index: 1)
        motion.advance(seconds: 0.02)
        let beforeClick = motion.position
        let beforeVelocity = motion.velocity
        motion.retarget(index: 0)
        check(close(motion.position, beforeClick) && close(motion.velocity, beforeVelocity),
              "quick button reversal preserves position and velocity")
        settle(&motion)
        check(motion.position == 0, "reversed button transition converges on its latest target")

        var sampled: [(Double, Double)] = []
        for fps in [30, 60, 120] {
            var candidate = ShelfPagingMotion()
            candidate.retarget(index: 1)
            for _ in 0..<(fps / 10) { candidate.advance(seconds: 1 / Double(fps)) }
            sampled.append((candidate.position, candidate.velocity))
            settle(&candidate, fps: fps)
            check(candidate.position == 1 && !candidate.isSettling, "spring settles correctly at \(fps) Hz")
        }
        check(sampled.allSatisfy { close($0.0, sampled[0].0) && close($0.1, sampled[0].1) },
              "equal elapsed time produces the same page position and velocity at 30/60/120 Hz")

        motion.retarget(index: 1, reduceMotion: true)
        check(motion.position == 1 && !motion.isSettling, "reduced motion completes a button transition immediately")
        motion.beginDrag()
        motion.drag(contentDeltaX: 180, pageWidth: 600)
        motion.endDrag(velocityContentX: 0, pageWidth: 600, cancelled: false, originSection: 1, reduceMotion: true)
        check(motion.position == 0 && !motion.isSettling, "reduced motion keeps paging outcome without a settling slide")
        motion.beginDrag()
        motion.drag(contentDeltaX: .nan, pageWidth: 600)
        motion.drag(contentDeltaX: -100, pageWidth: 0)
        check(motion.position == 0 && motion.position.isFinite, "invalid input cannot poison page position")
        motion.endDrag(velocityContentX: .nan, pageWidth: 0, cancelled: false, originSection: 0)
        motion.advance(seconds: .nan)
        check(motion.velocity.isFinite && motion.position.isFinite, "invalid timing or release velocity remains finite")
        motion.retarget(index: 99, reduceMotion: true)
        check(motion.position == 1, "invalid target indices clamp to available pages")
        print("Shelf paging motion checks passed: \(checks).")
    }
}
