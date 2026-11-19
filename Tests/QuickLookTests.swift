// Exercise the native preview and keyboard focus with temporary shelf copies.
import AppKit
import Quartz

@main
struct QuickLookTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("Quick Look checks passed."); exit(0) }
            catch { fputs("Quick Look failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor
    static func run() async throws {
        let app = NSApplication.shared
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let text = Data("Quick Look fixture".utf8)
        let file = base.appendingPathComponent("Example.txt")
        try text.write(to: file)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData, 0xff, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = base.appendingPathComponent("Capture.png")
        try png.write(to: image)

        let root = base.appendingPathComponent("shelf", isDirectory: true)
        let storage = try TrayStorage(root: root)
        let fileEntry = try storage.importFile(file)
        let imageEntry = try storage.importFile(image)
        let lastFile = try storage.importFile(file)
        let screenshot = try storage.importScreenshot(image, sourceID: "quick-look-fixture")!
        let lastScreenshot = try storage.importScreenshot(image, sourceID: "quick-look-fixture-2")!
        let controller = try TrayController(root: root)
        let shelf = controller.panel
        let systemPreview = QLPreviewPanel.shared()!
        var preview: NSWindow { shelf.previewWindow ?? systemPreview }
        var previewItemURL: URL? { shelf.imagePreview?.fileURL ?? systemPreview.currentPreviewItem?.previewItemURL }
        defer {
            shelf.closePreview()
            systemPreview.orderOut(nil)
            shelf.orderOut(nil)
        }

        app.activate()
        let trigger = controller.geometry.trigger
        let notch = NSPoint(x: trigger.midX, y: trigger.midY)
        // A separate panel can hold real keyboard focus without asking the user's
        // foreground application to yield activation during this fixture.
        let otherWindow = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 220, height: 120),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        otherWindow.hidesOnDeactivate = false
        defer { otherWindow.orderOut(nil) }

        func activeFrame(_ entry: TrayEntry) -> Bool {
            controller.view.tiles.contains { $0.entry.id == entry.id && $0.selected && $0.selectionActive }
        }

        func runEvents(for duration: TimeInterval) async throws {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
        func check(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date(timeIntervalSinceNow: 3)
            while !condition(), Date() < deadline { try await runEvents(for: 0.02) }
            guard condition() else {
                let item = previewItemURL?.lastPathComponent ?? "none"
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
                throw NSError(domain: "QuickLookTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(message). App active: \(app.isActive). Front: \(front). Shelf key: \(shelf.isKeyWindow). Preview visible: \(preview.isVisible), key: \(preview.isKeyWindow), item: \(item), frame: \(preview.frame)."])
            }
            print("PASS: \(message)")
        }
        func sendKey(_ characters: String, code: UInt16, to window: NSWindow) async throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code)!
            app.postEvent(event, atStart: true)
            try await runEvents(for: 0.02)
        }
        func checkPreview(_ entry: TrayEntry) async throws {
            // AppKit may reject activation of a window that already ignores input.
            // Make it inert only after it has received the focus under test.
            systemPreview.ignoresMouseEvents = false
            try await sendKey(" ", code: 49, to: shelf)
            try await check("Quick Look opens \(entry.name) and receives keyboard focus") {
                preview.isVisible && preview.isKeyWindow &&
                    previewItemURL?.path == controller.url(for: entry).path
            }
            preview.ignoresMouseEvents = true
            // Quick Look handles input after its opening transition finishes.
            try await runEvents(for: 0.4)
            let available = controller.geometry.previewFrame
            try await check("The entire preview of \(entry.name) fits below the expanded shelf") {
                available.insetBy(dx: -0.5, dy: -0.5).contains(preview.frame) &&
                    preview.frame.maxY < controller.geometry.frame(open: true).minY
            }
            // Providers can request a much larger frame after loading their content.
            preview.setFrame(NSRect(x: available.minX - 100, y: available.minY - 100,
                                    width: 3000, height: 2400), display: true)
            try await runEvents(for: 0.1)
            try await check("An oversized provider frame is fitted back below the shelf") {
                available.insetBy(dx: -0.5, dy: -0.5).contains(preview.frame)
            }
            preview.setFrameOrigin(NSPoint(x: available.minX, y: available.maxY))
            try await check("Moving the preview cannot cover the shelf") {
                preview.frame.maxY <= available.maxY + 0.5
            }
        }
        func checkReturnToShelf(_ entry: TrayEntry, message: String) async throws {
            try await check(message) {
                !preview.isVisible && shelf.isKeyWindow && shelf.firstResponder === controller.view &&
                    controller.isExpanded && controller.selection == [entry.id] && activeFrame(entry)
            }
        }

        func checkCurrent(_ entry: TrayEntry, message: String) async throws {
            try await check(message) {
                preview.isVisible && preview.isKeyWindow &&
                    previewItemURL?.path == controller.url(for: entry).path &&
                    controller.selection == [entry.id] && activeFrame(entry)
            }
            // Await the native preview transition before navigating again.
            try await runEvents(for: 0.4)
        }

        func arrow(_ direction: Int) async throws {
            try await sendKey(direction < 0 ? "\u{f702}" : "\u{f703}", code: direction < 0 ? 123 : 124, to: preview)
        }

        try await runEvents(for: 0.1)
        for origin in [NSPoint.zero, NSPoint(x: -1920, y: 240), NSPoint(x: 120, y: -900)] {
            let visible = NSRect(origin: origin, size: NSSize(width: 1280, height: 720))
            let shelfFrame = NSRect(x: visible.midX - 280, y: visible.maxY - 190, width: 560, height: 190)
            let available = PreviewWindowLayout.availableFrame(visibleFrame: visible, shelfFrame: shelfFrame)
            let fitted = PreviewWindowLayout.fittingFrame(NSRect(x: 0, y: 0, width: 6000, height: 4000), in: available, centered: true)
            try await check("Oversized content fits a screen at \(origin) without covering its shelf") {
                visible.contains(fitted) && fitted.maxY == shelfFrame.minY - 12 && fitted.width > 0 && fitted.height > 0
            }
        }
        controller.dragObserver.onMouseDown?(notch)
        try await check("Clicking the notch gives the shelf keyboard focus") { app.isActive && shelf.isKeyWindow }
        try await sendKey(" ", code: 49, to: shelf)
        try await check("Space with no selection leaves the preview closed") { !preview.isVisible }

        controller.selectOnly(fileEntry.id)
        controller.collapse()
        try await check("The closed shelf releases its focus before hover") { !shelf.isKeyWindow }
        otherWindow.makeKeyAndOrderFront(nil)
        try await check("Another window is ready to receive keyboard input") { otherWindow.isKeyWindow }
        controller.dragObserver.onHover?(notch)
        try await check("Hover shows a saved selection without taking keyboard focus") {
            controller.isExpanded && otherWindow.isKeyWindow && controller.selection == [fileEntry.id] && !activeFrame(fileEntry)
        }
        controller.dragObserver.onMouseDown?(notch)
        try await check("Clicking the already open notch activates the saved selection") {
            shelf.isKeyWindow && shelf.firstResponder === controller.view && activeFrame(fileEntry)
        }
        otherWindow.makeKey()
        try await check("Losing keyboard focus dims the selected card") { otherWindow.isKeyWindow && !activeFrame(fileEntry) }
        otherWindow.orderOut(nil)
        controller.dragObserver.onMouseDown?(notch)
        let originalMin = systemPreview.minSize
        let originalMax = systemPreview.maxSize
        try await checkPreview(fileEntry)
        try await sendKey(" ", code: 49, to: preview)
        try await checkReturnToShelf(fileEntry, message: "Space closes Quick Look and returns to the selected file")
        try await check("Closing releases the shared Quick Look window's size constraints") {
            systemPreview.minSize == originalMin && systemPreview.maxSize == originalMax
        }

        systemPreview.ignoresMouseEvents = false
        try await checkPreview(fileEntry)
        systemPreview.ignoresMouseEvents = false
        try await arrow(-1)
        try await checkCurrent(fileEntry, message: "Left stops at the first card")
        try await arrow(1)
        try await checkCurrent(imageEntry, message: "Right opens the next image and highlights its card")
        try await check("Navigating to an image offers editing for that image") {
            shelf.imagePreview?.fileURL == controller.url(for: imageEntry) && shelf.imagePreview?.onEdit != nil
        }
        try await arrow(1)
        try await checkCurrent(lastFile, message: "Right switches from the image back to the system preview")
        try await arrow(1)
        try await checkCurrent(lastFile, message: "Right stops at the last card")
        try await arrow(-1)
        try await checkCurrent(imageEntry, message: "Left returns to the image")
        try await sendKey(" ", code: 49, to: preview)
        try await checkReturnToShelf(imageEntry, message: "Space returns to the last browsed card")

        controller.selectOnly(fileEntry.id)
        controller.select(lastFile.id, modifiers: .command)
        try await checkPreview(fileEntry)
        try await arrow(1)
        try await checkCurrent(lastFile, message: "Multiple selection skips an unselected card")
        try await sendKey("\u{1b}", code: 53, to: preview)
        try await checkReturnToShelf(lastFile, message: "Escape keeps only the last browsed card selected")

        controller.switchSection(.screenshots)
        controller.view.finishSectionTransition()
        controller.selectOnly(screenshot.id)
        try await checkPreview(screenshot)
        let screenshotWindow = preview
        try await arrow(1)
        try await checkCurrent(lastScreenshot, message: "Right browses within Screenshots")
        try await arrow(-1)
        try await checkCurrent(screenshot, message: "Left restores the previous screenshot")
        try await check("Browsing screenshots reuses the same window") { preview === screenshotWindow }
        try await sendKey("\u{1b}", code: 53, to: preview)
        try await checkReturnToShelf(screenshot, message: "Escape closes Quick Look and returns to the selected screenshot")

        try await checkPreview(screenshot)
        controller.switchSection(.files)
        controller.view.finishSectionTransition()
        try await checkReturnToShelf(lastFile, message: "Switching sections dismisses Quick Look and restores that section's selection")

        let savedImage = try Data(contentsOf: controller.url(for: screenshot))
        let sourceImage = try Data(contentsOf: image)
        try await check("Preview preserves the screenshot copy, source and shelf entries") {
            savedImage == png && sourceImage == png && controller.entries.count == 5
        }

        systemPreview.ignoresMouseEvents = false
        controller.selectOnly(imageEntry.id)
        try await checkPreview(imageEntry)
        controller.importURLs([file])
        try await check("New files can arrive while the preview is open") { controller.entries.count == 6 && preview.isVisible }
        let newFile = controller.visibleEntries.last!
        try fm.removeItem(at: controller.url(for: lastFile))
        try await arrow(1)
        try await checkCurrent(imageEntry, message: "Navigation excludes a missing copy and does not include a new arrival")
        controller.removeEntry(imageEntry.id)
        try await checkCurrent(fileEntry, message: "Removing the current card moves to a remaining file")
        controller.removeEntry(fileEntry.id)
        try await check("Removing the last available item closes the session") { !shelf.isPreviewing && shelf.isKeyWindow }

        // Both copies in the selected set are unavailable.
        controller.selectOnly(lastFile.id)
        controller.select(newFile.id, modifiers: .command)
        try fm.removeItem(at: controller.url(for: newFile))
        try await sendKey(" ", code: 49, to: shelf)
        try await check("A missing copy reports the problem on the shelf") { !preview.isVisible && controller.hasError }
        let sourceFile = try Data(contentsOf: file)
        precondition(sourceFile == text)

        try await sendKey("\u{1b}", code: 53, to: shelf)
        try await check("Collapsing the shelf releases keyboard focus") { !controller.isExpanded && !shelf.isKeyWindow }
    }
}
