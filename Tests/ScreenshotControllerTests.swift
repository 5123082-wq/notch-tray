// Screenshot integration regressions use isolated files and no system capture.
import AppKit

@main
struct ScreenshotControllerTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("shelf", isDirectory: true)
        let storage = try TrayStorage(root: root)
        var checks = 0
        func check(_ valid: Bool, _ message: String) {
            precondition(valid, message)
            checks += 1
            print("PASS: \(message)")
        }
        func flush(_ controller: TrayController) {
            controller.io.sync {}
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            controller.io.sync {}
        }

        let document = base.appendingPathComponent("Обычный файл.txt")
        let documentBytes = Data("Unrelated ordinary file\n".utf8)
        try documentBytes.write(to: document)
        let ordinary = try storage.importFile(document)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<4 {
            for y in 0..<4 { image.setColor(NSColor(deviceRed: 0.2, green: 0.7, blue: 0.4, alpha: 1), atX: x, y: y) }
        }
        let imageBytes = image.representation(using: .png, properties: [:])!
        var screenshots: [TrayEntry] = []
        var originals: [URL] = []
        for index in 0..<4 {
            let url = base.appendingPathComponent("Снимок \(index + 1).png")
            try imageBytes.write(to: url)
            originals.append(url)
            screenshots.append(try storage.importScreenshot(url, sourceID: "fixture-\(index)")!)
        }

        let c = try TrayController(root: root, monitorScreenshots: false)
        c.panel.orderOut(nil)
        defer { c.panel.close() }
        flush(c)
        check(c.activeSection == .files, "ordinary files remain the initial section")
        check(c.visibleEntries.map(\.id) == [ordinary.id], "file section excludes screenshot cards")
        check(c.screenshotCount == 4, "camera count includes all active screenshots")
        check(c.view.tiles.map(\.entry.id) == [ordinary.id], "initial view renders only the active section")
        check(c.screenshotSettings.removeAfterDrag, "requested remove-after-drag behavior starts enabled")
        let settingsMenu = c.screenshotSettingsMenuItem().submenu!
        check(settingsMenu.items[0].state == .on && settingsMenu.items[1].state == .on,
              "screenshot settings menu reflects both enabled defaults")
        let removalToggle = settingsMenu.items[1]
        check(NSApp.sendAction(removalToggle.action!, to: removalToggle.target, from: removalToggle),
              "native menu invokes the remove-after-drag setting")
        check(!c.screenshotSettings.removeAfterDrag &&
              c.screenshotSettingsMenuItem().submenu!.items[1].state == .off,
              "menu toggle changes saved behavior and its checkmark")
        _ = NSApp.sendAction(removalToggle.action!, to: removalToggle.target, from: removalToggle)
        check(c.screenshotSettings.removeAfterDrag, "menu can restore remove-after-drag behavior")

        c.selectAll()
        check(c.selection == [ordinary.id], "select-all is scoped to the file section")
        c.switchSection(.screenshots)
        check(Set(c.visibleEntries.map(\.id)) == Set(screenshots.map(\.id)), "screenshot section has its own collection")
        check(Set(c.view.tiles.map(\.entry.id)) == Set(screenshots.map(\.id)), "section switching reloads the correct cards")
        c.selectAll()
        check(c.selection == Set(screenshots.map(\.id)), "select-all cannot reach hidden ordinary files")

        c.outgoingFinished(success: false, ids: [screenshots[0].id])
        flush(c)
        check(c.screenshotCount == 4, "cancelled or rejected drag retains screenshot cards")

        // The callback must use the exact original drag payload, not whichever
        // cards happen to be selected when the asynchronous result arrives.
        c.selectOnly(screenshots[3].id)
        c.outgoingFinished(success: true, ids: [screenshots[0].id, screenshots[1].id, ordinary.id])
        flush(c)
        check(Set(c.entries.map(\.id)) == [ordinary.id, screenshots[2].id, screenshots[3].id],
              "successful batch removes only offered screenshot IDs, never normal files or later selection")
        check(c.screenshotCount == 2, "screenshot count updates after a batch transfer")
        for entry in screenshots.prefix(2) {
            check(fm.fileExists(atPath: c.url(for: entry).path), "transferred copy remains readable by the receiving application")
        }
        for url in originals {
            check(try Data(contentsOf: url) == imageBytes, "transfer preserves original \(url.lastPathComponent)")
        }
        check(try Data(contentsOf: document) == documentBytes, "transfer preserves ordinary original")

        var settings = c.screenshotSettings
        settings.removeAfterDrag = false
        settings.automaticImport = false
        settings.customFolderPath = base.path
        try c.saveScreenshotSettings(settings)
        c.outgoingFinished(success: true, ids: [screenshots[2].id])
        flush(c)
        check(c.entries.contains(where: { $0.id == screenshots[2].id }), "disabled remove-after-drag retains successfully transferred screenshots")
        let saved = try ScreenshotSettingsStore(root: root)
        check(saved.settings.automaticImport == settings.automaticImport &&
              saved.settings.removeAfterDrag == settings.removeAfterDrag &&
              saved.settings.customFolderPath == settings.customFolderPath,
              "all screenshot settings persist together")

        settings.removeAfterDrag = true
        try c.saveScreenshotSettings(settings)
        c.outgoingFinished(success: true, ids: [])
        flush(c)
        check(c.screenshotCount == 2, "empty or missing drag payload never removes current selection")
        c.outgoingFinished(success: true, ids: [UUID()])
        flush(c)
        check(c.screenshotCount == 2, "stale drag IDs cannot remove unrelated screenshots")

        c.removeEntry(screenshots[2].id)
        flush(c)
        check(c.screenshotCount == 1, "manual removal only removes its screenshot")
        c.clearShelf()
        flush(c)
        check(c.screenshotCount == 0 && c.visibleEntries.isEmpty, "clearing screenshot section returns its empty state")
        check(c.entries.map(\.id) == [ordinary.id], "clearing screenshots preserves ordinary files")
        c.switchSection(.files)
        check(c.visibleEntries.map(\.id) == [ordinary.id], "ordinary files remain usable after screenshot cleanup")

        let restarted = try TrayStorage(root: root)
        try restarted.collectRetired(now: Date(timeIntervalSinceNow: 90_000))
        for (index, original) in originals.enumerated() {
            check(try restarted.importScreenshot(original, sourceID: "fixture-\(index)") == nil,
                  "removed screenshot \(index + 1) stays suppressed after restart and retired-copy cleanup")
            check(try Data(contentsOf: original) == imageBytes, "cleanup preserves original \(index + 1)")
        }
        check(restarted.items.map(\.id) == [ordinary.id], "source deduplication cannot recreate removed cards")
        let finalSettings = try ScreenshotSettingsStore(root: root)
        check(finalSettings.settings.removeAfterDrag && !finalSettings.settings.automaticImport,
              "latest settings survive recreation independently of screenshot contents")
        flush(c)
        print("Screenshot controller checks passed: \(checks).")
    }
}
