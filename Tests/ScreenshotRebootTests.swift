import Foundation
import CoreGraphics
import ImageIO
import Darwin

@main
struct ScreenshotRebootTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("screenshot-reboot-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        func wait(_ label: String, until predicate: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 7)
            while !predicate(), Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            precondition(predicate(), "TIMEOUT: \(label)")
        }
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let png = data as Data
        func screenshot(_ url: URL) throws {
            try png.write(to: url)
            let marker = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = marker.withUnsafeBytes { bytes in
                url.path.withCString { path in
                    "com.apple.metadata:kMDItemIsScreenCapture".withCString {
                        setxattr(path, $0, bytes.baseAddress, marker.count, 0, 0)
                    }
                }
            }
            precondition(result == 0)
        }
        // Preserve the actual inode and birth time but model a previous boot's st_dev.
        func legacyID(_ url: URL) throws -> String {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let device = (attributes[.systemNumber] as! NSNumber).int64Value
            let inode = attributes[.systemFileNumber] as! NSNumber
            let created = attributes[.creationDate] as! Date
            return "\(device + 100):\(inode):\(created.timeIntervalSinceReferenceDate)"
        }
        func manifestVersion(_ root: URL) throws -> Int {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shelf.json"))) as! [String: Any]
            return document["version"] as! Int
        }

        for version in [1, 2] {
            let folder = base.appendingPathComponent("captures-v\(version)")
            let root = base.appendingPathComponent("store-v\(version)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent("archive.png")
            let removed = folder.appendingPathComponent("removed.png")
            let active = folder.appendingPathComponent("active.png")
            let returning = folder.appendingPathComponent("returning.png")
            for url in [archive, removed, active, returning] { try screenshot(url) }
            let originalIdentities = [archive, removed, active, returning].map { ScreenshotFile.inspect($0)!.identity }
            let legacyIDs = try [archive, removed, active, returning].map(legacyID)
            let seed = try TrayStorage(root: root)
            try seed.baselineScreenshotFolder(folder.path, sourceIDs: [legacyIDs[0], legacyIDs[3]])
            let retired = try seed.importScreenshot(removed, sourceID: legacyIDs[1])!
            let activeEntry = try seed.importScreenshot(active, sourceID: legacyIDs[2])!
            try seed.remove(ids: [retired.id], now: Date(timeIntervalSinceNow: -90_000))
            try seed.collectRetired()
            // Write the historical schema and copy-only revision as an old release did.
            let manifest = root.appendingPathComponent("shelf.json")
            var historical = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            var historicalEntries = historical["entries"] as! [[String: Any]]
            historicalEntries[0].removeValue(forKey: "screenshotSourcePath")
            if version == 2 {
                var edited = activeEntry
                edited.imageRevision = UUID()
                historicalEntries[0]["imageRevision"] = edited.imageRevision!.uuidString
                let copy = seed.url(for: edited)
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: copy)
            }
            historical["entries"] = historicalEntries
            historical["version"] = version
            try JSONSerialization.data(withJSONObject: historical).write(to: manifest)
            try check(try manifestVersion(root) == version, "fixture starts in legacy manifest v\(version)")
            let hidden = base.appendingPathComponent("absent-v\(version).png")
            try fm.moveItem(at: returning, to: hidden)
            let offline = folder.appendingPathComponent("new-while-stopped.png")
            try screenshot(offline)
            let before = try Data(contentsOf: manifest)
            let store = try TrayStorage(root: root)
            let originalCards = store.items
            let queue = DispatchQueue(label: "notch.reboot-test-v\(version)")
            var current = store.items
            var status: ScreenshotMonitorStatus?
            let monitor = ScreenshotMonitor(storage: store, queue: queue) { entries, state in current = entries; status = state }
            var settings = ScreenshotSettings()
            settings.customFolderPath = folder.path
            monitor.start(settings: settings)
            wait("offline capture imports after v\(version) migration") { current.contains { $0.name == offline.lastPathComponent } }
            try check(status?.issue == nil, "v\(version) migration reports no import error")
            try check(current.count == 2 && !current.contains { [archive.lastPathComponent, removed.lastPathComponent].contains($0.name) },
                      "changed device number does not reimport archived or removed/cleaned screenshots (v\(version))")
            try check(current.contains(originalCards[0]), "migration preserves active card identity and edited revision (v\(version))")
            try check(try manifestVersion(root) == 3, "persistent identity upgrades storage to v3 (from v\(version))")
            let backup = root.appendingPathComponent("shelf-before-screenshot-identity.json")
            try check(try Data(contentsOf: backup) == before, "migration saves exact pre-upgrade manifest (v\(version))")
            try check(queue.sync { Set(legacyIDs).isSubset(of: store.processedScreenshotSources) }, "migration retains complete legacy journal (v\(version))")
            try check(queue.sync { originalIdentities.prefix(3).allSatisfy { store.processedScreenshotSources.contains($0.sourceID) } },
                      "archive, removed and active sources receive persistent identities (v\(version))")
            try check(!fm.fileExists(atPath: seed.url(for: retired).path), "migration does not recreate retired copies (v\(version))")
            for url in [archive, removed, active, offline] {
                try check(try Data(contentsOf: url) == png, "migration preserves original \(url.lastPathComponent) (v\(version))")
            }
            try fm.moveItem(at: hidden, to: returning)
            wait("returning source migrates") { queue.sync { store.processedScreenshotSources.contains(originalIdentities[3].sourceID) } }
            try check(queue.sync { store.items.count == 2 }, "temporarily absent old source is remembered when it returns (v\(version))")
            try check(try Data(contentsOf: backup) == before, "later migration never overwrites backup (v\(version))")

            let original = originalIdentities[0]
            let otherVolume = ScreenshotIdentity(volumeUUID: UUID().uuidString, inode: original.inode, created: original.created)
            let reusedInode = ScreenshotIdentity(volumeUUID: original.volumeUUID, inode: original.inode, created: original.created.addingTimeInterval(1))
            try queue.sync { try store.migrateScreenshotSources(in: folder.path, identities: [otherVolume, reusedInode]) }
            try check(queue.sync { !store.processedScreenshotSources.contains(otherVolume.sourceID) && !store.processedScreenshotSources.contains(reusedInode.sourceID) },
                      "migration does not consume new files on other volumes or reused inodes (v\(version))")
            monitor.stop()
            queue.sync {}
            let offlineEntry = store.items.first { $0.name == offline.lastPathComponent }!
            try store.remove(ids: [offlineEntry.id], now: Date(timeIntervalSinceNow: -90_000))
            try store.collectRetired()
            let renamed = folder.appendingPathComponent("renamed-after-next-boot.png")
            try fm.moveItem(at: offline, to: renamed)
            try check(ScreenshotFile.inspect(renamed)?.sourceID == offlineEntry.screenshotSourceID, "persistent identity survives rename (v\(version))")
            let nextNew = folder.appendingPathComponent("new-after-next-boot.png")
            try screenshot(nextNew)
            let reopened = try TrayStorage(root: root)
            current = reopened.items
            let restarted = ScreenshotMonitor(storage: reopened, queue: queue) { entries, _ in current = entries }
            restarted.start(settings: settings)
            wait("next startup imports only fresh capture") { current.contains { $0.name == nextNew.lastPathComponent } }
            restarted.stop()
            queue.sync {}
            try check(current.count == 2 && current.contains(originalCards[0]), "another restart keeps removed and renamed sources excluded (v\(version))")
            try check(try Data(contentsOf: backup) == before, "restarts and cleanup preserve migration backup (v\(version))")
            let editedLegacy = try reopened.saveEditedImage(png, for: originalCards[0].id, expectedRevision: originalCards[0].imageRevision)
            try check(editedLegacy.screenshotSourcePath == active.path && editedLegacy.screenshotSourceID == ScreenshotFile.inspect(active)?.sourceID,
                      "Save resolves a v\(version) card without a source path after device migration")
        }

        // A failed backup/commit must stop import, keep the old ledger, and retry safely.
        let failedFolder = base.appendingPathComponent("failed-captures")
        try fm.createDirectory(at: failedFolder, withIntermediateDirectories: true)
        let old = failedFolder.appendingPathComponent("old.png")
        try screenshot(old)
        let failedRoot = base.appendingPathComponent("failed-store")
        let failed = try TrayStorage(root: failedRoot)
        let oldID = try legacyID(old)
        try failed.baselineScreenshotFolder(failedFolder.path, sourceIDs: [oldID])
        try failed.migrateScreenshotSources(in: "/never-observed-folder", identities: [ScreenshotFile.inspect(old)!.identity])
        try check(failed.processedScreenshotSources == [oldID], "legacy migration is limited to previously observed folders")
        let fresh = failedFolder.appendingPathComponent("fresh.png")
        try screenshot(fresh)
        let blockedManifest = failedRoot.appendingPathComponent("shelf.json")
        let safeManifest = failedRoot.appendingPathComponent("saved-manifest.json")
        let previousBytes = try Data(contentsOf: blockedManifest)
        try fm.moveItem(at: blockedManifest, to: safeManifest)
        try fm.createDirectory(at: blockedManifest, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "notch.failed-reboot-test")
        var status: ScreenshotMonitorStatus?
        var imported: [TrayEntry] = []
        let monitor = ScreenshotMonitor(storage: failed, queue: queue) { entries, state in imported = entries; status = state }
        var settings = ScreenshotSettings()
        settings.customFolderPath = failedFolder.path
        monitor.start(settings: settings)
        wait("migration error is reported") { status?.issue != nil }
        try check(queue.sync { failed.processedScreenshotSources == [oldID] && failed.items.isEmpty }, "failed migration preserves in-memory state and imports nothing")
        try check(try fm.contentsOfDirectory(atPath: failed.files.path).isEmpty, "failed migration leaves no partial copies")
        try fm.removeItem(at: blockedManifest)
        try fm.moveItem(at: safeManifest, to: blockedManifest)
        monitor.update(settings: settings)
        wait("migration retries") { imported.count == 1 }
        monitor.stop()
        queue.sync {}
        try check(imported[0].name == fresh.lastPathComponent, "successful retry imports only the unprocessed capture")
        try check(try Data(contentsOf: failedRoot.appendingPathComponent("shelf-before-screenshot-identity.json")) == previousBytes,
                  "retry backs up intact original manifest")
        try check(try Data(contentsOf: old) == png && Data(contentsOf: fresh) == png, "failed migration and retry preserve original files")
        print("\(checks) screenshot reboot checks passed")
    }
}
