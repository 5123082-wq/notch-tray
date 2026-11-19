// Hover regressions drive one pointer through real view/window coordinates.
// No user shelf, system clipboard, or synthesized system input is touched.
import AppKit
import QuartzCore

@main
struct FileTileTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("shelf", isDirectory: true)
        let storage = try TrayStorage(root: root)
        var originals: [(URL, Data)] = []
        let names = ["Заметки.txt", "План.txt", "Список.txt"] + (4...10).map { "Файл \($0).txt" }
        for (index, name) in names.enumerated() {
            let source = base.appendingPathComponent(name)
            let data = Data("Hover remove fixture \(index)\n".utf8)
            try data.write(to: source)
            try storage.importFile(source)
            originals.append((source, data))
        }
        let c = try TrayController(root: root)
        c.panel.orderOut(nil)
        defer { c.panel.close() }
        c.isExpanded = true
        c.isPinned = true
        c.panel.setFrame(c.geometry.frame(open: true), display: false)
        c.view.layoutSubtreeIfNeeded()
        c.view.present(expansion: 1)
        c.selectAll()
        var checks = 0
        func check(_ valid: Bool, _ message: String) {
            precondition(valid, message)
            checks += 1
            print("PASS: \(message)")
        }
        func screenPoint(_ point: NSPoint, in view: NSView) -> NSPoint {
            c.panel.convertPoint(toScreen: view.convert(point, to: nil))
        }
        func center(_ view: NSView) -> NSPoint {
            screenPoint(NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
        }
        func assertHover(_ expected: UUID?, _ message: String) {
            let visible = c.view.tiles.filter { !$0.removeButton.isHidden }.map(\.entry.id)
            check(visible == (expected.map { [$0] } ?? []), message)
        }
        func move(to point: NSPoint, expecting expected: UUID?, _ message: String) {
            c.view.updateHover(at: point)
            assertHover(expected, message)
        }
        func scrollToRow(containing tile: FileTile) {
            c.view.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, tile.frame.minY - 2)))
            c.view.scroll.reflectScrolledClipView(c.view.scroll.contentView)
            c.view.layoutSubtreeIfNeeded()
        }
        let outside = screenPoint(NSPoint(x: -20, y: -20), in: c.view)
        move(to: outside, expecting: nil, "no remove controls appear outside the shelf")
        c.dragObserver.onHover?(center(c.view.tiles[0].icon))
        assertHover(c.view.tiles[0].entry.id, "the existing mouse monitor updates the single hovered file")
        c.dragObserver.onHover?(outside)
        assertHover(nil, "the existing mouse monitor clears hover when leaving")

        // A single pointer crosses many cards repeatedly without synthesizing
        // perfectly paired mouseEntered/mouseExited callbacks for each card.
        for pass in 0..<3 {
            let orderedTiles = pass.isMultiple(of: 2) ? c.view.tiles : c.view.tiles.reversed().map { $0 }
            for tile in orderedTiles {
                scrollToRow(containing: tile)
                move(to: center(tile.icon), expecting: tile.entry.id,
                     "sweep \(pass + 1): exactly one remove control on \(tile.entry.name)")
                move(to: center(tile.removeButton), expecting: tile.entry.id,
                     "moving onto the close control preserves its file")
                move(to: center(tile.nameField), expecting: tile.entry.id,
                     "moving onto the filename preserves its file")
            }
        }
        scrollToRow(containing: c.view.tiles[0])
        let first = c.view.tiles[0]
        let second = c.view.tiles[1]
        move(to: center(first.icon), expecting: first.entry.id, "first file acquires hover")
        let staleEnter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: c.panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let staleExit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: c.panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        second.mouseEntered(with: staleEnter)
        first.mouseExited(with: staleExit)
        assertHover(first.entry.id, "stale per-card tracking events cannot override the current pointer")
        let gap = screenPoint(NSPoint(x: first.frame.maxX + 1, y: first.frame.midY), in: c.view.grid)
        move(to: gap, expecting: nil, "gap between files clears every remove control")
        move(to: center(c.view.menuButton), expecting: nil, "footer controls do not retain a file hover")
        move(to: center(second.icon), expecting: second.entry.id, "return from footer selects only the current file")
        move(to: outside, expecting: nil, "leaving the shelf clears all file hover states")

        let hiddenPoint = second.removeButton.convert(NSPoint(x: second.removeButton.bounds.midX,
            y: second.removeButton.bounds.midY), to: second.superview)
        check(second.hitTest(hiddenPoint) === second, "hidden close control leaves tile interaction intact")
        move(to: center(second.removeButton), expecting: second.entry.id, "close control appears under its file's pointer")
        check(second.hitTest(hiddenPoint) === second.removeButton, "visible close control receives its click")
        let iconPoint = second.convert(NSPoint(x: second.icon.frame.midX, y: second.icon.frame.midY), to: second.superview)
        check(second.hitTest(iconPoint) === second, "thumbnail still routes to native tile dragging")

        c.armExternalDrag()
        assertHover(nil, "starting incoming drag clears all close controls")
        move(to: center(second.icon), expecting: nil, "incoming drag cannot restore a close control")
        let shelfPoint = second.removeButton.convert(NSPoint(x: second.removeButton.bounds.midX,
            y: second.removeButton.bounds.midY), to: c.view.superview)
        check(c.view.hitTest(shelfPoint) === c.view, "incoming drag over close control belongs to the shelf")
        c.finishExternalDrag()
        move(to: center(second.icon), expecting: second.entry.id, "hover recovers after incoming drag")
        c.isDraggingOut = true
        assertHover(nil, "starting outgoing drag clears all close controls")
        move(to: center(first.icon), expecting: nil, "outgoing drag cannot restore a close control")
        second.removeButton.performClick(nil)
        c.io.sync {}
        check(c.storage.items.count == names.count, "remove action cannot discard a file during outgoing drag")
        c.isDraggingOut = false

        move(to: center(second.icon), expecting: second.entry.id, "hover recovers after outgoing drag")
        c.isExpanded = false
        c.view.present(expansion: 0)
        assertHover(nil, "collapsing the shelf clears hover")
        move(to: center(second.icon), expecting: nil, "collapsed shelf cannot acquire file hover")
        c.isExpanded = true
        c.view.present(expansion: 0.5)
        move(to: center(second.icon), expecting: nil, "partial reveal cannot expose close controls")
        c.view.present(expansion: 1)
        move(to: center(first.icon), expecting: first.entry.id, "reopening shows only the current file's control")

        // Scrolling replaces the file at a stationary screen position. Hidden
        // rows cannot keep a close control, even if their own frames contain it.
        let stationary = center(first.icon)
        scrollToRow(containing: c.view.tiles[5])
        move(to: stationary, expecting: c.view.tiles[5].entry.id, "scroll changes hover to the visible row under the pointer")
        move(to: center(first.icon), expecting: nil, "a clipped offscreen file cannot acquire hover")
        scrollToRow(containing: first)
        move(to: stationary, expecting: first.entry.id, "scrolling back restores exactly one current control")
        c.view.reload()
        c.view.layoutSubtreeIfNeeded()
        move(to: stationary, expecting: c.view.tiles[0].entry.id, "reloading cards does not accumulate old hover states")

        c.selectAll()
        let tile = c.view.tiles[1]
        let removed = tile.entry
        let remainingIDs = Set(c.entries.filter { $0.id != removed.id }.map(\.id))
        let removedCopy = c.url(for: removed)
        let retainedCopies = c.entries.filter { $0.id != removed.id }.map { c.url(for: $0) }
        let retainedBytes = try retainedCopies.map { try Data(contentsOf: $0) }
        c.view.layoutSubtreeIfNeeded()
        move(to: center(tile.icon), expecting: tile.entry.id, "only the deletion target is hovered in a multi-selection")
        try render(c.view, to: output.appendingPathComponent("hover-remove-preview.png"))

        tile.removeButton.performClick(nil)
        c.io.sync {}
        let deadline = Date(timeIntervalSinceNow: 3)
        while c.entries.contains(where: { $0.id == removed.id }), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        check(Set(c.entries.map(\.id)) == remainingIDs, "hover remove deletes only its file from a multi-selection")
        check(c.selection == remainingIDs, "other selected files stay selected")
        check(c.view.tiles.count == names.count - 1, "shelf reloads with every other file")
        check(c.view.tiles.filter { !$0.removeButton.isHidden }.count <= 1, "deletion and relayout cannot leave multiple close controls")
        check(fm.fileExists(atPath: removedCopy.path), "removed copy stays available for existing drop recipients")
        for (copy, bytes) in zip(retainedCopies, retainedBytes) {
            check(try Data(contentsOf: copy) == bytes, "remaining shelf copy \(copy.lastPathComponent) is unchanged")
        }
        for (source, bytes) in originals {
            check(try Data(contentsOf: source) == bytes, "original \(source.lastPathComponent) is unchanged")
        }
        let reloaded = try TrayStorage(root: root)
        check(Set(reloaded.items.map(\.id)) == remainingIDs, "single-file removal persists after reopening storage")
        c.io.sync {}
        print("File hover-removal checks passed: \(checks). Preview: \(output.appendingPathComponent("hover-remove-preview.png").path)")
    }

    private static func render(_ view: NSView, to output: URL) throws {
        let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])!.write(to: output)
    }
}
