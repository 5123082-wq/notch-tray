// Keep native previews within the usable screen area below the shelf. GPL-3.0.
import AppKit

final class PreviewWindowLayout {
    static func availableFrame(visibleFrame: NSRect, shelfFrame: NSRect) -> NSRect {
        let inset = visibleFrame.insetBy(dx: 12, dy: 12)
        return NSRect(x: inset.minX, y: inset.minY, width: max(1, inset.width),
                      height: max(1, min(inset.maxY, shelfFrame.minY - 12) - inset.minY))
    }

    static func fittingFrame(_ frame: NSRect, in available: NSRect, centered: Bool = false) -> NSRect {
        let size = NSSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
        let origin = centered ? NSPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2) : frame.origin
        return NSRect(x: min(max(origin.x, available.minX), available.maxX - size.width),
                      y: min(max(origin.y, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private weak var window: NSWindow?
    private var availableFrame: NSRect
    private let originalMinSize: NSSize
    private let originalMaxSize: NSSize
    private var observers: [NSObjectProtocol] = []
    private var applyingFrame = false

    init(window: NSWindow, availableFrame: NSRect) {
        self.window = window
        self.availableFrame = availableFrame
        originalMinSize = window.minSize
        originalMaxSize = window.maxSize
        // Quick Look may resize again after its preview provider loads. A maximum
        // alone does not constrain programmatic setFrame calls, so observe both.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.constrain()
            })
        }
        update(availableFrame: availableFrame)
    }

    func update(availableFrame: NSRect) {
        self.availableFrame = availableFrame
        constrain(centered: true)
    }

    private func constrain(centered: Bool = false) {
        guard let window, !applyingFrame else { return }
        applyingFrame = true
        defer { applyingFrame = false }
        window.minSize = NSSize(width: min(originalMinSize.width, availableFrame.width),
                                height: min(originalMinSize.height, availableFrame.height))
        window.maxSize = availableFrame.size
        let fitted = Self.fittingFrame(window.frame, in: availableFrame, centered: centered)
        if window.frame != fitted { window.setFrame(fitted, display: true) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // QLPreviewPanel is shared; do not leave our constraints on its next owner.
        window?.minSize = originalMinSize
        window?.maxSize = originalMaxSize
    }
}
