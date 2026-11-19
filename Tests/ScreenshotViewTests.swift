// Section navigation regressions use real view coordinates and isolated copies.
// No screenshot monitoring, user folders, or synthesized system input is used.
import AppKit

@main
struct ScreenshotViewTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("shelf", isDirectory: true)
        let storage = try TrayStorage(root: root)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<32 {
            let color = x < 16 ? NSColor(deviceRed: 0.3, green: 0.8, blue: 0.65, alpha: 1) :
                NSColor(deviceRed: 0.3, green: 0.3, blue: 0.7, alpha: 1)
            for y in 0..<20 { image.setColor(color, atX: x, y: y) }
        }
        let imageBytes = image.representation(using: .png, properties: [:])!
        var files: [TrayEntry] = []
        var screenshots: [TrayEntry] = []
        for index in 1...12 {
            let file = base.appendingPathComponent("Файл \(index).txt")
            try Data("Ordinary fixture \(index)".utf8).write(to: file)
            files.append(try storage.importFile(file))
            let screenshot = base.appendingPathComponent("Снимок \(index).png")
            try imageBytes.write(to: screenshot)
            screenshots.append(try storage.importScreenshot(screenshot, sourceID: "view-\(index)")!)
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
        func check(_ valid: Bool, _ message: String) {
            precondition(valid, message)
            checks += 1
            print("PASS: \(message)")
        }
        func scroll(to y: CGFloat) -> CGFloat {
            c.view.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            c.view.scroll.reflectScrolledClipView(c.view.scroll.contentView)
            c.view.layoutSubtreeIfNeeded()
            return c.view.scroll.contentView.bounds.origin.y
        }
        func pointInScreen(_ view: NSView) -> NSPoint {
            c.panel.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        }
        func flush() {
            c.io.sync {}
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            c.view.layoutSubtreeIfNeeded()
        }

        check(c.view.filesButton.state == .on && c.view.screenshotsButton.state == .off,
              "initial section buttons identify Files without opening screenshots")
        check(c.view.screenshotsButton.title == "12", "camera displays the screenshot count while Files is active")
        check(c.view.screenshotsButton.accessibilityLabel() == "Скриншоты, 12",
              "camera exposes its collection and count to accessibility")
        c.selectOnly(files[6].id)
        let fileScroll = scroll(to: 112)
        let oldTile = c.view.tiles[6]
        c.view.updateHover(at: pointInScreen(oldTile.icon))
        check(c.view.hoveredEntryID == oldTile.entry.id, "scrolled file acquires the sole hover control")

        c.view.screenshotsButton.performClick(nil)
        c.view.finishSectionTransition()
        c.view.layoutSubtreeIfNeeded()
        check(c.activeSection == .screenshots && c.view.screenshotsButton.state == .on,
              "camera button switches the visible collection")
        check(c.selection.isEmpty && c.view.scroll.contentView.bounds.origin.y == 0,
              "first visit to screenshots has independent selection and scroll")
        check(c.view.page(for: .files).isHidden && c.view.hoveredEntryID != oldTile.entry.id,
              "changing sections hides the persistent file page and clears its hover")
        c.selectOnly(screenshots[1].id)
        let screenshotScroll = scroll(to: 210)
        c.view.filesButton.performClick(nil)
        c.view.finishSectionTransition()
        c.view.layoutSubtreeIfNeeded()
        check(c.selection == [files[6].id] && c.anchor == files[6].id,
              "returning to Files restores its selection and range anchor")
        check(c.view.scroll.contentView.bounds.origin.y == fileScroll,
              "returning to Files restores its vertical position")
        c.view.screenshotsButton.performClick(nil)
        c.view.finishSectionTransition()
        c.view.layoutSubtreeIfNeeded()
        check(c.selection == [screenshots[1].id] && c.anchor == screenshots[1].id,
              "screenshots restore their independent selection and range anchor")
        check(c.view.scroll.contentView.bounds.origin.y == screenshotScroll,
              "screenshots restore their independent vertical position")

        let nextImage = base.appendingPathComponent("Новый снимок.png")
        try imageBytes.write(to: nextImage)
        c.entries = try c.io.sync {
            _ = try c.storage.importScreenshot(nextImage, sourceID: "view-new")
            return c.storage.items
        }
        c.view.reload()
        c.view.layoutSubtreeIfNeeded()
        check(c.view.scroll.contentView.bounds.origin.y == screenshotScroll,
              "appending a screenshot does not jump the visible collection to the top")
        check(c.view.screenshotsButton.title == "13" && c.selection == [screenshots[1].id],
              "new snapshot updates camera count while preserving selection")
        check(c.view.tiles.filter { !$0.removeButton.isHidden }.count <= 1,
              "section changes and reloads retain a single hover owner")
        check(!c.view.subtitle.stringValue.isEmpty && c.view.subtitle.toolTip == c.screenshotStatusText,
              "screenshot source status is available with its full tooltip")

        c.isDraggingOut = true
        check(!c.view.filesButton.isEnabled && !c.view.screenshotsButton.isEnabled,
              "navigation is disabled while a screenshot is being dragged")
        c.view.filesButton.performClick(nil)
        check(c.activeSection == .screenshots, "dragging cannot switch the collection under its source")
        c.isDraggingOut = false
        _ = scroll(to: 0)
        let representation = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds)!
        c.view.cacheDisplay(in: c.view.bounds, to: representation)
        try representation.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("screenshot-section-preview.png"))

        c.clearShelf()
        flush()
        check(c.view.tiles.isEmpty && c.view.scroll.isHidden,
              "removing the last screenshots presents their empty state")
        check(c.view.screenshotsButton.title.isEmpty && c.view.screenshotsButton.imagePosition == .imageOnly,
              "empty camera becomes a compact icon without a zero badge")
        check(c.view.emptyHint.stringValue.contains("⇧⌘4") && c.view.emptyHint.stringValue.contains("⇧⌘3"),
              "empty screenshots explain the standard system shortcuts")
        c.view.filesButton.performClick(nil)
        c.view.finishSectionTransition()
        c.view.layoutSubtreeIfNeeded()
        check(c.view.tiles.count == files.count && c.selection == [files[6].id],
              "clearing screenshots leaves ordinary file cards and selection intact")
        check(c.view.scroll.contentView.bounds.origin.y == fileScroll,
              "clearing screenshots leaves ordinary file scrolling intact")
        c.isExpanded = false
        c.view.present(expansion: 0)
        check(c.view.hoveredEntryID == nil && c.view.hitTest(.zero) == nil,
              "new navigation preserves the invisible noninteractive collapsed shelf")
        flush()
        print("Screenshot view checks passed: \(checks).")
    }
}
