// AppKit routing checks use in-memory events, never posted to the system.
// Source files, copies, and screenshot monitoring are isolated from user data.
import AppKit

private final class ShelfScrollFixture: NSEvent {
    var targetWindow: NSWindow?
    var point = NSPoint.zero
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scrollPhase: NSEvent.Phase = .changed
    var inertia: NSEvent.Phase = []
    var precise = true
    var time: TimeInterval = 0
    var flags: NSEvent.ModifierFlags = []
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var timestamp: TimeInterval { time }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
}

@main
struct ShelfSwipeIntegrationTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("shelf")
        let store = try TrayStorage(root: root)
        var files: [TrayEntry] = []
        var shots: [TrayEntry] = []
        // Storage supplies independent collections; no image recognition is
        // involved in these gesture-only fixtures.
        for index in 0..<15 {
            let file = base.appendingPathComponent("file-\(index).txt")
            try Data("fixture \(index)".utf8).write(to: file)
            files.append(try store.importFile(file))
            shots.append(try store.importScreenshot(file, sourceID: "gesture-\(index)")!)
        }
        let c = try TrayController(root: root, monitorScreenshots: false)
        c.panel.orderOut(nil)
        defer { c.panel.close() }
        c.isExpanded = true
        c.isPinned = true
        c.panel.setFrame(c.geometry.frame(open: true), display: false)
        c.view.layoutSubtreeIfNeeded()
        c.view.present(expansion: 1)
        var checks = 0
        var clock: TimeInterval = 100
        func check(_ valid: Bool, _ message: String) {
            precondition(valid, message)
            checks += 1
            print("PASS: \(message)")
        }
        func windowPoint(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        // The pointer remains in the viewport while its pages translate.
        let viewportPoint = windowPoint(c.view.scroll)
        func event(_ x: CGFloat, _ y: CGFloat = 0, phase: NSEvent.Phase = .changed,
                   at point: NSPoint? = nil, momentum: NSEvent.Phase = [],
                   after interval: TimeInterval = 0.02) -> ShelfScrollFixture {
            clock += interval
            let event = ShelfScrollFixture()
            event.targetWindow = c.panel
            event.point = point ?? viewportPoint
            event.x = x; event.y = y; event.scrollPhase = phase
            event.inertia = momentum; event.time = clock
            return event
        }
        @discardableResult
        func send(_ x: CGFloat, _ y: CGFloat = 0, phase: NSEvent.Phase = .changed,
                  at point: NSPoint? = nil, momentum: NSEvent.Phase = [],
                  after interval: TimeInterval = 0.02) -> Bool {
            c.view.handleSectionScroll(event(x, y, phase: phase, at: point,
                                            momentum: momentum, after: interval))
        }
        func finish() {
            _ = send(0, phase: .ended)
            c.view.finishSectionTransition()
            c.view.layoutSubtreeIfNeeded()
        }
        func select(_ section: ShelfSection) {
            c.switchSection(section)
            c.view.finishSectionTransition()
            c.view.layoutSubtreeIfNeeded()
        }
        func scroll(to y: CGFloat) -> CGFloat {
            c.view.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            c.view.scroll.reflectScrolledClipView(c.view.scroll.contentView)
            c.view.layoutSubtreeIfNeeded()
            return c.view.scroll.contentView.bounds.origin.y
        }

        let width = c.view.page(for: .files).bounds.width
        precondition(width > 100, "page width is available after layout")
        var forwarded: [NSEvent] = []
        c.view.forwardVerticalScroll = { forwarded.append($0) }
        c.selectOnly(files[6].id)
        let fileScroll = scroll(to: 112)
        let tilePoint = windowPoint(c.view.tiles[6])
        check(send(0, 3, phase: .began, at: tilePoint),
              "initial vertical jitter is buffered before either direction is chosen")
        check(forwarded.isEmpty && c.view.sectionPosition == 0,
              "undecided motion neither scrolls the file list nor moves the pages")
        check(send(-8, 1) && send(-18, 1),
              "clear horizontal intent after initial vertical jitter is captured")
        check(c.activeSection == .files && c.view.sectionPosition > 0 && c.view.sectionPosition < 1,
              "horizontal content follows fingers continuously before logical section changes")
        check(!c.view.page(for: .files).isHidden && !c.view.page(for: .screenshots).isHidden &&
              c.view.page(for: .files).tiles.count == files.count &&
              c.view.page(for: .screenshots).tiles.count == shots.count,
              "both live collections remain visible during interactive paging")
        let filePage = c.view.page(for: .files)
        let screenshotPage = c.view.page(for: .screenshots)
        check(abs(Double(filePage.frame.minX) + c.view.sectionPosition * Double(width)) < 0.01,
              "AppKit file frame follows the exact interactive page displacement")
        check(abs(screenshotPage.frame.minX - filePage.frame.minX - width) < 0.01 &&
              !filePage.visibleRect.isEmpty && !screenshotPage.visibleRect.isEmpty,
              "both adjacent pages have visible AppKit content and stay exactly one page apart")
        let positionBeforeHitTest = c.view.sectionPosition
        check(c.view.hitTest(c.view.convert(viewportPoint, from: nil)) === c.view &&
              c.view.sectionPosition == positionBeforeHitTest && c.view.isSectionMoving,
              "hit testing moving content absorbs tile clicks without finishing the gesture")
        check(forwarded.isEmpty && c.view.scroll.contentView.bounds.origin.y == fileScroll,
              "horizontal resolution discards buffered vertical jitter without scrolling the list")
        let initialProgress = c.view.sectionPosition
        _ = send(-width * 0.35, 70)
        check(c.view.sectionPosition > initialProgress && c.activeSection == .files && forwarded.isEmpty,
              "horizontal axis stays locked despite later vertical drift")
        let releasePosition = c.view.sectionPosition
        _ = send(0, phase: .ended)
        check(c.activeSection == .screenshots && c.view.isSectionMoving,
              "release commits a deliberate drag and starts settling toward Screenshots")
        check(abs(c.view.sectionPosition - releasePosition) < 0.0001,
              "release begins its animation at the finger's final position")
        check(send(150, phase: [], momentum: .began) && c.activeSection == .screenshots &&
              abs(c.view.sectionPosition - releasePosition) < 0.0001,
              "horizontal momentum is consumed without navigating")
        _ = send(150, phase: [], momentum: .ended)
        c.view.advanceSectionMotion(seconds: 0.035)
        check(c.view.sectionPosition > releasePosition && c.view.sectionPosition < 1,
              "settling advances smoothly between release position and destination")
        c.view.finishSectionTransition()
        c.view.layoutSubtreeIfNeeded()
        check(c.view.sectionPosition == 1 && !c.view.isSectionMoving &&
              c.view.page(for: .files).isHidden && !c.view.page(for: .screenshots).isHidden,
              "completed transition rests exactly on Screenshots and hides the inactive page")
        check(c.selection.isEmpty && c.view.scroll.contentView.bounds.origin.y == 0,
              "first swiped visit has independent selection and scroll")

        c.selectOnly(shots[8].id)
        let screenshotScroll = scroll(to: 200)
        let toolbarPoint = windowPoint(c.view.screenshotsButton)
        check(send(width * 0.4, phase: .began, at: toolbarPoint),
              "horizontal gesture over the toolbar follows the same route")
        check(c.activeSection == .screenshots && c.view.sectionPosition < 1,
              "return swipe moves toward Files while preserving its screenshot source until release")
        finish()
        check(c.activeSection == .files, "positive horizontal content delta returns to Files")
        check(c.selection == [files[6].id] && c.anchor == files[6].id,
              "swiping restores file selection and range anchor")
        check(c.view.scroll.contentView.bounds.origin.y == fileScroll,
              "swiping restores the file collection's vertical position")
        _ = send(-width * 0.4, phase: .began)
        finish()
        check(c.selection == [shots[8].id] && c.anchor == shots[8].id &&
              c.view.scroll.contentView.bounds.origin.y == screenshotScroll,
              "returning by swipe restores screenshot selection and scroll")

        forwarded.removeAll()
        let verticalStart = event(1, -3, phase: .began)
        let verticalResolve = event(1, -22)
        let verticalDrift = event(100, -2)
        let verticalEnd = event(0, phase: .ended)
        let verticalMomentum = event(0, -100, phase: [], momentum: .began)
        let verticalMomentumEnd = event(0, phase: [], momentum: .ended)
        check(c.view.handleSectionScroll(verticalStart) && forwarded.isEmpty,
              "small vertical beginning waits for an unambiguous direction")
        check(c.view.handleSectionScroll(verticalResolve) && forwarded.count == 2 &&
              forwarded[0] === verticalStart && forwarded[1] === verticalResolve,
              "vertical resolution forwards the original began and changed events in order")
        check(c.view.handleSectionScroll(verticalDrift) && c.activeSection == .screenshots,
              "vertical direction lock prevents later horizontal drift from changing sections")
        _ = c.view.handleSectionScroll(verticalEnd)
        _ = c.view.handleSectionScroll(verticalMomentum)
        _ = c.view.handleSectionScroll(verticalMomentumEnd)
        let expected: [NSEvent] = [verticalStart, verticalResolve, verticalDrift, verticalEnd,
                                  verticalMomentum, verticalMomentumEnd]
        check(forwarded.count == expected.count && zip(forwarded, expected).allSatisfy { $0.0 === $0.1 },
              "vertical stream including end and momentum reaches native scrolling exactly once")
        check(c.view.sectionPosition == 1 && !c.view.isSectionMoving,
              "vertical scrolling never animates the horizontal page strip")

        check(send(16, phase: .began), "short horizontal intent moves the page without committing")
        let shortProgress = c.view.sectionPosition
        _ = send(0, phase: .stationary, after: 0.3)
        _ = send(0, phase: .ended, after: 0.3)
        check(shortProgress < 1 && c.activeSection == .screenshots,
              "short held drag releases back to the original section")
        c.view.finishSectionTransition()
        check(c.view.sectionPosition == 1, "short gesture snaps back exactly to its origin")
        _ = send(width * 0.4, phase: .began)
        check(send(100, phase: .cancelled) && c.activeSection == .screenshots,
              "cancelling an otherwise sufficient drag keeps the original section")
        c.view.finishSectionTransition()
        check(c.view.sectionPosition == 1, "cancelled gesture restores the original page position")
        check(send(-100, phase: .began) && c.activeSection == .screenshots && c.view.sectionPosition > 1,
              "outward boundary swipe does not wrap around")
        finish()
        check(c.view.sectionPosition == 1, "elastic boundary returns to the last page")

        select(.files)
        _ = send(-width * 0.4, phase: .began)
        let outwardProgress = c.view.sectionPosition
        _ = send(width * 0.36)
        check(c.view.sectionPosition < outwardProgress && c.activeSection == .files,
              "reversing fingers reverses page motion within the same gesture")
        finish()
        check(c.activeSection == .files && c.view.sectionPosition == 0,
              "reversed gesture can return to Files instead of committing an earlier threshold crossing")

        _ = send(-width * 0.35, phase: .began)
        _ = send(0, phase: .ended)
        c.view.advanceSectionMotion(seconds: 0.025)
        let interruptedPosition = c.view.sectionPosition
        check(interruptedPosition > 0 && interruptedPosition < 1 && c.view.isSectionMoving,
              "interruption fixture starts between pages during settling")
        _ = send(0, phase: .began)
        check(abs(c.view.sectionPosition - interruptedPosition) < 0.0001,
              "fresh gesture grabs the currently presented position without a jump")
        c.view.advanceSectionMotion(seconds: 0.04)
        check(abs(c.view.sectionPosition - interruptedPosition) < 0.0001,
              "undecided new gesture freezes settling while the user establishes direction")
        _ = send(20)
        check(c.view.sectionPosition < interruptedPosition &&
              abs(c.view.sectionPosition - interruptedPosition) < 0.1,
              "interrupted drag continues from its fractional position instead of the committed page")
        _ = send(0, phase: .cancelled)
        c.view.finishSectionTransition()
        select(.screenshots)

        let foreign = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: .borderless, backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { foreign.close() }
        let other = event(100, phase: .began)
        other.targetWindow = foreign
        check(!c.view.handleSectionScroll(other) && c.activeSection == .screenshots,
              "events belonging to another window cannot switch the shelf")
        let outside = c.view.convert(NSPoint(x: -20, y: -20), to: nil)
        check(!send(100, phase: .began, at: outside) && c.activeSection == .screenshots,
              "events outside the visible shelf are ignored")
        let modified = event(100, phase: .began)
        modified.flags = .shift
        check(!c.view.handleSectionScroll(modified), "modified scrolling is not interpreted as a trackpad page swipe")
        let wheel = event(100, phase: .began)
        wheel.precise = false
        check(!c.view.handleSectionScroll(wheel), "coarse mouse-wheel events do not change sections")

        c.isExpanded = false
        check(!send(100, phase: .began), "collapsed shelf cannot respond to a swipe")
        c.isExpanded = true
        c.view.present(expansion: 0.5)
        check(!send(100, phase: .began), "partially revealed shelf cannot switch midway through expansion")
        c.view.present(expansion: 1)
        c.choosingFiles = true
        check(!send(100, phase: .began), "folder/file chooser blocks section swipes")
        c.choosingFiles = false
        c.incomingDrag = true
        check(!send(100, phase: .began), "incoming file drag blocks section swipes")
        c.incomingDrag = false
        c.isDraggingOut = true
        check(!send(100, phase: .began), "outgoing file drag blocks section swipes")
        c.isDraggingOut = false
        c.armExternalDrag()
        check(!send(100, phase: .began), "armed external drag blocks section swipes before drop entry")
        c.finishExternalDrag()
        check(c.activeSection == .screenshots, "all guarded events preserve the active section")
        check(!send(100), "a blocked gesture cannot resume from a changed event after unblocking")

        // A genuinely empty collection must still be navigable over its labels.
        c.entries = c.entries.filter { $0.category == .files }
        c.view.reload()
        c.view.layoutSubtreeIfNeeded()
        check(c.view.scroll.isHidden && c.view.tiles.isEmpty, "empty screenshot fixture presents its native empty state")
        let emptyPoint = windowPoint(c.view.emptyTitle)
        check(send(width * 0.4, phase: .began, at: emptyPoint) && c.view.sectionPosition < 1,
              "swipe over empty-state content moves toward the main file shelf")
        finish()
        check(c.activeSection == .files, "empty-state gesture commits Files on release")
        check(c.view.tiles.count == files.count && c.selection == [files[6].id],
              "empty-section navigation preserves the ordinary files and their selection")
        c.view.forwardVerticalScroll = nil

        // Exercise AppKit's actual scrolling implementation separately from the
        // routing spy. These events stay in memory and are never posted. The
        // deadline catches a regression into AppKit's concurrent event tracker,
        // which would otherwise wait forever for an OS-delivered gesture stream.
        let nativeDeadline = DispatchWorkItem {
            fputs("FAIL: native vertical scrolling did not return within five seconds\n", stderr)
            exit(EXIT_FAILURE)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: nativeDeadline)
        defer { nativeDeadline.cancel() }
        let nativeScroll = c.view.page(for: .files).scroll
        let nativeOrigin = scroll(to: 0)
        func deliverNative(_ delta: Int32, phase: CGScrollPhase? = nil,
                           momentum: CGMomentumScrollPhase = .none) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                             wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.location = CGPoint(x: viewportPoint.x,
                                  y: NSScreen.screens[0].frame.maxY - viewportPoint.y)
            cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            let native = NSEvent(cgEvent: cg)!
            precondition(native.hasPreciseScrollingDeltas, "native fixture preserves precise scrolling")
            nativeScroll.scrollWheel(with: native)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        deliverNative(-15, phase: .began)
        deliverNative(-15, phase: .changed)
        deliverNative(0, phase: .ended)
        let fingerOrigin = nativeScroll.contentView.bounds.origin.y
        check(fingerOrigin > nativeOrigin,
              "real native began/changed/ended events scroll the file list and return without tracking a new stream")
        // NSEvent(cgEvent:) has windowNumber 0, so this fixture cannot establish
        // AppKit's native inertia target. Momentum must still return promptly;
        // the routing spy above verifies its exact event identity and order.
        deliverNative(-12, momentum: .begin)
        // Raw value of kCGMomentumScrollPhaseContinue in CGEventTypes.h.
        deliverNative(-8, momentum: CGMomentumScrollPhase(rawValue: 2)!)
        deliverNative(0, momentum: .end)
        check(c.activeSection == .files && c.view.sectionPosition == 0 &&
              c.selection == [files[6].id] && nativeScroll.contentView.bounds.origin.x == 0,
              "native scrolling and momentum return while preserving the page, selection, and horizontal position")
        nativeDeadline.cancel()
        c.io.sync {}
        print("Shelf swipe integration checks passed: \(checks).")
    }
}
