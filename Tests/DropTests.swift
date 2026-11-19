// Native AppKit regression checks. No user files or drag pasteboard are modified.
import AppKit

private final class TestDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    deinit { draggingPasteboard.releaseGlobally() }
}

@main struct DropTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let c = try TrayController(root: base.appendingPathComponent("shelf"))
        defer { c.panel.close() }
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            print("PASS: \(message)")
        }
        func waitForImport() {
            let deadline = Date(timeIntervalSinceNow: 10)
            while c.busy > 0, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            check(c.busy == 0, "import completes without a second drop")
        }
        check(c.panel.ignoresMouseEvents, "idle menu bar clicks pass through")
        c.armExternalDrag()
        check(!c.panel.ignoresMouseEvents, "collapsed notch accepts drag before pointer entry")
        check(c.view.hitTest(NSPoint(x: c.view.bounds.midX, y: 8)) === c.view,
              "zero-reveal notch has a native drop destination")
        c.finishExternalDrag()
        check(c.panel.ignoresMouseEvents, "cancelled drag restores idle click-through")
        c.armExternalDrag()
        c.expand()
        check(c.view.hitTest(NSPoint(x: c.view.bounds.midX, y: 8)) === c.view,
              "first reveal frame accepts drop")
        for progress in [0.0, 0.01, 0.5, 1.0] {
            c.view.present(expansion: progress)
            c.view.layoutSubtreeIfNeeded()
            for y in stride(from: 5.0, to: c.view.bounds.height - 5, by: 20) {
                for x in stride(from: 5.0, to: c.view.bounds.width - 5, by: 20) {
                    checkHit(c.view.hitTest(NSPoint(x: x, y: y)) === c.view)
                }
            }
        }
        check(true, "one drop destination across the shelf throughout reveal")
        check(c.view.emptyIcon.registeredDraggedTypes.isEmpty, "decorative image cannot intercept PDF/file drops")
        let drag = TestDrag()
        drag.draggingDestinationWindow = c.panel
        let pdf = base.appendingPathComponent("Документ #1.pdf")
        let pdfData = Data("%PDF-1.4\n% Drop regression fixture\n%%EOF\n".utf8)
        try pdfData.write(to: pdf)
        drag.draggingPasteboard.writeObjects([pdf as NSURL])
        check(c.view.draggingEntered(drag) == .copy, "first PDF drag is accepted")
        check(c.view.prepareForDragOperation(drag), "first PDF drop prepares successfully")
        check(c.view.performDragOperation(drag), "first PDF drop starts import")
        c.view.concludeDragOperation(drag)
        waitForImport()
        check(c.entries.count == 1 && !c.hasError, "first PDF drop creates one shelf item")
        check(try Data(contentsOf: c.url(for: c.entries[0])) == pdfData, "PDF bytes preserved")
        check(try Data(contentsOf: pdf) == pdfData, "original PDF unchanged")
        c.armExternalDrag()
        c.view.present(expansion: 1)
        c.view.layoutSubtreeIfNeeded()
        let tile = c.view.tiles[0]
        let tilePoint = tile.convert(NSPoint(x: 20, y: 20), to: c.view.superview)
        check(c.view.hitTest(tilePoint) === c.view, "populated tile routes incoming drop to shelf")
        c.finishExternalDrag()
        check(c.view.hitTest(tilePoint) === tile, "normal tile interaction restored after drop")
        drag.draggingSourceOperationMask = .move
        check(c.view.draggingEntered(drag).isEmpty && !c.view.prepareForDragOperation(drag), "move-only source rejected without altering original")
        drag.draggingSourceOperationMask = .copy
        c.isDraggingOut = true
        check(!c.view.prepareForDragOperation(drag) && !c.view.performDragOperation(drag), "outgoing shelf drag cannot reimport itself")
        c.isDraggingOut = false
        let folder = base.appendingPathComponent("Папка")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: folder.appendingPathComponent("child.txt"))
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([pdf as NSURL, folder as NSURL])
        check(c.view.performDragOperation(drag), "multi-file and folder drop accepted")
        c.view.concludeDragOperation(drag)
        waitForImport()
        check(c.entries.count == 3 && !c.hasError, "multi-file drop imports every item")
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.setString("plain text", forType: .string)
        check(c.view.draggingEntered(drag).isEmpty, "unsupported text rejected")
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([base.appendingPathComponent("missing.pdf") as NSURL])
        check(c.view.performDragOperation(drag), "missing file reaches import error handling")
        waitForImport()
        check(c.hasError && c.entries.count == 3, "unreadable source reports error and preserves shelf")
        c.io.sync {}
        print("Native drop regression checks passed.")
    }
    static func checkHit(_ valid: Bool) { precondition(valid, "Drop target lost during reveal") }
}
