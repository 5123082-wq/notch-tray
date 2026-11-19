// Runtime cleanup uses isolated storage, shortened timers, and no synthetic input.
import AppKit

@main
struct CleanupTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var checks = 0
        func check(_ valid: Bool, _ message: String) {
            precondition(valid, message)
            checks += 1
            print("PASS: \(message)")
        }
        func pump(_ seconds: TimeInterval = 0.15) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        let source = base.appendingPathComponent("original.txt")
        let bytes = Data("Cleanup must preserve originals".utf8)
        try bytes.write(to: source)
        let root = base.appendingPathComponent("shelf")
        let initial = try TrayStorage(root: root)
        let startup = try initial.importFile(source)
        try initial.remove(ids: [startup.id], now: Date(timeIntervalSinceNow: -90_000))
        let c = try TrayController(root: root, cleanupInterval: 0.03)
        c.panel.orderOut(nil)
        defer { c.panel.close() }
        func exists(_ entry: TrayEntry) -> Bool { fm.fileExists(atPath: c.url(for: entry).path) }
        func retired(_ age: TimeInterval = 90_000) throws -> TrayEntry {
            try c.io.sync {
                let entry = try c.storage.importFile(source)
                try c.storage.remove(ids: [entry.id], now: Date(timeIntervalSinceNow: -age))
                return entry
            }
        }
        pump()
        check(!exists(startup), "startup cleans expired copies")
        let periodic = try retired()
        let fresh = try retired(60)
        let active = try c.io.sync { try c.storage.importFile(source) }
        pump()
        check(!exists(periodic), "timer cleans expired copies without restarting")
        check(exists(fresh), "timer preserves recently removed copies")
        check(exists(active), "timer preserves active storage entries")
        c.isDraggingOut = true
        let dragged = try retired()
        pump()
        check(exists(dragged), "cleanup is deferred during outgoing drag")
        c.isDraggingOut = false
        pump()
        check(!exists(dragged), "cleanup resumes after outgoing drag")
        c.incomingDrag = true
        let incoming = try retired()
        pump()
        check(exists(incoming), "cleanup is deferred during incoming drag")
        c.incomingDrag = false
        pump()
        check(!exists(incoming), "cleanup resumes after incoming drag")
        let pending = try retired()
        c.entries = [pending]
        pump()
        check(exists(pending), "UI entries remain usable while removal snapshot is pending")
        c.entries = []
        pump()
        check(!exists(pending), "retired copy is collected after UI releases it")
        let preview = try retired()
        c.entries = [preview]
        c.showPinned()
        c.selectOnly(preview.id)
        c.previewSelection()
        check(c.panel.isPreviewing, "isolated Quick Look preview opens")
        c.entries = []
        pump()
        check(exists(preview), "open preview protects retired file independently of shelf entries")
        c.panel.closePreview()
        pump()
        check(!exists(preview), "closing preview releases retired file")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = base.appendingPathComponent("image.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let edited = try c.io.sync { try c.storage.importFile(png) }
        c.entries = [edited]
        c.editImage(edited.id)
        let deadline = Date(timeIntervalSinceNow: 5)
        while c.imageEditors[edited.id] == nil && Date() < deadline { pump(0.02) }
        check(c.imageEditors[edited.id] != nil, "isolated image editor opens")
        try c.io.sync { try c.storage.remove(ids: [edited.id], now: Date(timeIntervalSinceNow: -90_000)) }
        c.entries = []
        pump()
        check(exists(edited), "editor protects expired copy after card removal")
        c.imageEditors[edited.id]?.requestClose { _ in }
        pump()
        check(!exists(edited), "closing editor releases expired copy")
        let wake = try TrayController(root: base.appendingPathComponent("wake-shelf"), cleanupInterval: 3600)
        wake.panel.orderOut(nil)
        defer { wake.panel.close() }
        pump()
        let awakened = try wake.io.sync {
            let entry = try wake.storage.importFile(source)
            try wake.storage.remove(ids: [entry.id], now: Date(timeIntervalSinceNow: -90_000))
            return entry
        }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        pump()
        check(!fm.fileExists(atPath: wake.url(for: awakened).path), "wake triggers cleanup before next timer")
        check(try Data(contentsOf: source) == bytes, "all cleanup paths preserve original contents")
        print("\(checks) runtime cleanup checks passed.")
    }
}
