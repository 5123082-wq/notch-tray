import Foundation
import ImageIO
import CoreGraphics
import Darwin

@main
struct ScreenshotStorageTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("screenshots-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        func pump(_ seconds: Double) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        }
        func wait(_ label: String, until predicate: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 7)
            while !predicate(), Date() < deadline { pump(0.04) }
            guard predicate() else { fatalError("TIMEOUT: \(label)") }
        }
        let bitmap = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = bitmap.makeImage()!
        let pngData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("cannot create fixture image") }
        let png = pngData as Data
        func screenshot(_ url: URL, data: Data? = nil, marked: Bool = true) throws {
            try (data ?? png).write(to: url)
            if marked {
                let marker = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
                let result = marker.withUnsafeBytes { bytes in
                    url.path.withCString { path in
                        "com.apple.metadata:kMDItemIsScreenCapture".withCString {
                            setxattr(path, $0, bytes.baseAddress, marker.count, 0, 0)
                        }
                    }
                }
                guard result == 0 else { fatalError("cannot mark screenshot fixture: \(errno)") }
            }
        }

        // Existing version 0.3.2 manifests have no category or ledger.
        let root = base.appendingPathComponent("store")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacy = "[{\"id\":\"\(legacyID.uuidString)\",\"name\":\"old.txt\",\"added\":0}]"
        try Data(legacy.utf8).write(to: root.appendingPathComponent("shelf.json"))
        let storage = try TrayStorage(root: root)
        try check(storage.items.first?.category == .files, "legacy entries migrate as ordinary files")
        let folder = base.appendingPathComponent("captures")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let archived = folder.appendingPathComponent("old.png")
        try screenshot(archived)
        let queue = DispatchQueue(label: "notch.screenshot-tests")
        var current: [TrayEntry] = storage.items
        var status: ScreenshotMonitorStatus?
        var updates = 0
        let monitor = ScreenshotMonitor(storage: storage, queue: queue) { entries, state in
            current = entries; status = state; updates += 1
        }
        var settings = ScreenshotSettings()
        settings.customFolderPath = folder.path
        monitor.start(settings: settings)
        wait("initial status") { status != nil }
        try check(current.filter { $0.category == .screenshots }.isEmpty, "first launch excludes existing screenshot archive")
        try check(try Data(contentsOf: root.appendingPathComponent("shelf-v0.3-backup.json")) == Data(legacy.utf8),
                  "migration preserves exact legacy manifest for rollback")

        let ordinary = folder.appendingPathComponent("Screenshot 2026-11-09.png")
        try screenshot(ordinary, marked: false)
        let fresh = folder.appendingPathComponent("任意のお名前.png")
        try screenshot(fresh)
        wait("new screenshot") { current.contains { $0.name == fresh.lastPathComponent } }
        try check(!current.contains { $0.name == ordinary.lastPathComponent }, "a screenshot-like filename alone is not imported")
        try check(current.filter { $0.category == .screenshots }.count == 1, "marked image imports in screenshot category regardless of filename")
        try check(try Data(contentsOf: fresh) == png, "automatic import preserves original bytes")
        let entry = current.first { $0.category == .screenshots }!
        try check(try Data(contentsOf: storage.url(for: entry)) == png, "shelf contains an independent complete copy")

        let partial = folder.appendingPathComponent("partial.png")
        try screenshot(partial, data: png.prefix(24))
        pump(1.8)
        try check(!current.contains { $0.name == partial.lastPathComponent }, "incomplete image is not imported")
        try screenshot(partial)
        // Updating a non-observation preference must not baseline away this pending file.
        settings.removeAfterDrag = false
        monitor.update(settings: settings)
        wait("completed partial") { current.contains { $0.name == partial.lastPathComponent } }
        try check(current.filter { $0.category == .screenshots }.count == 2, "completed image imports after a preference-only update")

        let edited = try queue.sync { try storage.saveEditedImage(png, for: entry.id, expectedRevision: nil) }
        let sourceID = ScreenshotFile.inspect(fresh)!.sourceID
        try check(edited.screenshotSourceID == sourceID && ScreenshotFile.hasScreenshotMetadata(fresh),
                  "saving replaces the marked original under the same name")
        pump(1.6)
        try check(queue.sync { storage.items.filter { $0.category == .screenshots }.count == 2 },
                  "the live folder monitor skips the edited screenshot")
        try queue.sync {
            try storage.remove(ids: [entry.id], now: Date(timeIntervalSinceNow: -90_000))
            try storage.collectRetired()
        }
        try check(!fm.fileExists(atPath: storage.url(for: entry).path), "retired screenshot copy is eventually cleaned")
        try check(fm.fileExists(atPath: fresh.path), "retired cleanup keeps system original")
        try check(queue.sync { storage.processedScreenshotSources.contains(sourceID) }, "source ledger survives retired copy cleanup")
        let renamed = folder.appendingPathComponent("renamed.png")
        try fm.moveItem(at: fresh, to: renamed)
        try check(ScreenshotFile.inspect(renamed)?.sourceID == sourceID, "source identity survives rename")
        pump(1.6)
        try check(queue.sync { storage.items.filter { $0.screenshotSourceID == sourceID }.isEmpty }, "removed and renamed original is not reimported")

        settings.automaticImport = false
        monitor.update(settings: settings)
        wait("disabled status") { status?.isEnabled == false }
        let paused = folder.appendingPathComponent("while-disabled.png")
        try screenshot(paused)
        settings.automaticImport = true
        monitor.update(settings: settings)
        wait("enabled status") { status?.isEnabled == true }
        pump(1.3)
        try check(!current.contains { $0.name == paused.lastPathComponent }, "re-enabling ignores captures from the disabled period")

        // A failed validation cannot consume the source ID or leave a visible copy.
        let invalidated = folder.appendingPathComponent("validation.png")
        try screenshot(invalidated)
        do {
            _ = try queue.sync { try storage.importScreenshot(invalidated, sourceID: "forced-validation", validateCopy: { _ in false }) }
            fatalError("validation unexpectedly succeeded")
        } catch TrayStorageError.screenshotChanged {
            try check(queue.sync { !storage.processedScreenshotSources.contains("forced-validation") }, "failed copied-image validation does not consume source ID")
        }
        monitor.stop()
        queue.sync {}
        let reopened = try TrayStorage(root: root)
        try check(reopened.processedScreenshotSources.contains(sourceID), "removed source ledger persists across restart")
        try check(reopened.items.contains { $0.id == legacyID && $0.category == .files }, "manifest migration retains ordinary files")
        try check(try Data(contentsOf: root.appendingPathComponent("shelf-v0.3-backup.json")) == Data(legacy.utf8),
                  "later commits never overwrite original migration backup")
        try check(try reopened.importScreenshot(renamed, sourceID: sourceID) == nil, "restart cannot reimport a retired source")

        let settingsStore = try ScreenshotSettingsStore(root: root)
        try settingsStore.save(settings)
        let settingsReloaded = try ScreenshotSettingsStore(root: root).settings
        try check(settingsReloaded.automaticImport && !settingsReloaded.removeAfterDrag && settingsReloaded.customFolderPath == folder.path,
                  "screenshot preferences persist")
        // Same status without import does not force rebuilding the shelf repeatedly.
        let before = updates
        pump(0.2)
        try check(updates == before, "stopped monitor produces no periodic UI refresh")
        print("\(checks) screenshot storage checks passed")
    }
}
