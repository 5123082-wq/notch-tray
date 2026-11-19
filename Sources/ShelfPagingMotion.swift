// Notch Tray — GPL-3.0.
import Foundation

/// A two-page, directly manipulated strip. Coordinates are pages, not pixels:
/// 0 is Files and 1 is Screenshots. Content deltas already follow macOS settings.
struct ShelfPagingMotion {
    private(set) var position: Double
    private(set) var velocity = 0.0
    private(set) var targetIndex: Int
    private(set) var isDragging = false
    private var dragOrigin = 0.0
    private var dragTranslation = 0.0

    private static let angularFrequency = 32.0
    private static let rubberConstant = 0.55

    init(index: Int = 0) {
        targetIndex = min(1, max(0, index))
        position = Double(targetIndex)
    }

    var isSettling: Bool {
        !isDragging && (abs(position - Double(targetIndex)) > 0.0007 || abs(velocity) > 0.015)
    }

    /// Interrupt at the actual presented value, never at the previous target.
    mutating func beginDrag() {
        dragOrigin = Self.unresisted(position)
        dragTranslation = 0
        isDragging = true
        velocity = 0
    }

    mutating func drag(contentDeltaX: Double, pageWidth: Double) {
        guard isDragging, contentDeltaX.isFinite, pageWidth.isFinite, pageWidth > 0 else { return }
        dragTranslation -= contentDeltaX / pageWidth
        position = Self.resisted(dragOrigin + dragTranslation)
    }

    /// A deliberate slow drag commits after one fifth of the page. A short,
    /// directional flick may commit earlier; reversing velocity can return it.
    mutating func endDrag(velocityContentX: Double, pageWidth: Double,
                          cancelled: Bool, originSection: Int, reduceMotion: Bool = false) {
        guard isDragging else { return }
        isDragging = false
        let origin = min(1, max(0, originSection))
        let direction = origin == 0 ? 1.0 : -1.0
        let normalizedVelocity: Double
        if velocityContentX.isFinite, pageWidth.isFinite, pageWidth > 0 {
            normalizedVelocity = min(8, max(-8, -velocityContentX / pageWidth))
        } else { normalizedVelocity = 0 }

        let progress = (position - Double(origin)) * direction
        let towardNeighbor = normalizedVelocity * direction
        let projectedProgress = progress + towardNeighbor * 0.18
        if cancelled {
            targetIndex = origin
        } else if towardNeighbor <= -0.65 {
            // A clear return flick can reverse an otherwise committed drag.
            targetIndex = projectedProgress >= 0.5 ? 1 - origin : origin
        } else if towardNeighbor >= 0.65, abs(dragTranslation) >= 0.035,
                  projectedProgress >= 0.2 {
            targetIndex = 1 - origin
        } else {
            targetIndex = progress >= 0.2 ? 1 - origin : origin
        }
        velocity = normalizedVelocity
        if reduceMotion { finish() }
    }

    /// Button transitions can reverse an existing settling animation without
    /// resetting its position or velocity.
    mutating func retarget(index: Int, reduceMotion: Bool = false) {
        targetIndex = min(1, max(0, index))
        isDragging = false
        if reduceMotion { finish() }
    }

    /// Analytic critically damped spring; identical elapsed time gives the same
    /// result at 30, 60, and 120 Hz without frame-rate-dependent integration.
    mutating func advance(seconds: Double) {
        guard !isDragging, seconds.isFinite, seconds > 0 else { return }
        guard isSettling else { finish(); return }
        let omega = Self.angularFrequency
        let displacement = position - Double(targetIndex)
        let coefficient = velocity + omega * displacement
        let decay = exp(-omega * seconds)
        position = Double(targetIndex) + (displacement + coefficient * seconds) * decay
        velocity = (velocity - omega * coefficient * seconds) * decay
        if !isSettling { finish() }
    }

    mutating func finish() {
        position = Double(targetIndex)
        velocity = 0
        isDragging = false
    }

    private static func resisted(_ value: Double) -> Double {
        if value < 0 { return -rubberDistance(-value) }
        if value > 1 { return 1 + rubberDistance(value - 1) }
        return value
    }

    private static func rubberDistance(_ distance: Double) -> Double {
        distance * rubberConstant / (1 + distance * rubberConstant)
    }

    private static func unresisted(_ value: Double) -> Double {
        let distance = value < 0 ? -value : max(0, value - 1)
        guard distance > 0 else { return value }
        // The inverse preserves the exact visible value when an elastic edge
        // is grabbed again. Clamp only the mathematical singularity at 1 page.
        let d = min(0.999999, distance)
        let raw = d / (rubberConstant * (1 - d))
        return value < 0 ? -raw : 1 + raw
    }
}
