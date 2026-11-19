import Foundation
import AppKit

@main
struct StorageTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError("FAIL: \(message)") }
            checks += 1
            print("PASS: \(message)")
        }
        let source = base.appendingPathComponent("Исходники")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("Договор #1 🟢.txt")
        let contents = Data("Тест сохранности оригинала\n".utf8)
        try contents.write(to: original)
        let root = base.appendingPathComponent("Shelf")
        let storage = try TrayStorage(root: root)
        let entry = try storage.importFile(original)
        try check(try Data(contentsOf: original) == contents, "import preserves original")
        try check(try Data(contentsOf: storage.url(for: entry)) == contents, "copy has identical contents")
        try check(entry.name == original.lastPathComponent, "Unicode and special characters preserved")
        let duplicate = try storage.importFile(original)
        try check(storage.url(for: entry) != storage.url(for: duplicate), "duplicate names have independent paths")
        try check(storage.items.count == 2, "multiple items retained")
        try fm.removeItem(at: original)
        try check(try Data(contentsOf: storage.url(for: entry)) == contents, "shelf survives original removal")
        let folder = source.appendingPathComponent("Папка", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try contents.write(to: folder.appendingPathComponent("child.txt"))
        let folderEntry = try storage.importFile(folder)
        try check(try Data(contentsOf: storage.url(for: folderEntry).appendingPathComponent("child.txt")) == contents, "folder contents copied recursively")
        let reopened = try TrayStorage(root: root)
        try check(reopened.items == storage.items, "manifest restores shelf after restart")
        do {
            _ = try storage.importFile(source.appendingPathComponent("missing.txt"))
            fatalError("missing import unexpectedly succeeded")
        } catch { try check(storage.items.count == 3, "failed import does not alter shelf") }
        let old = Date(timeIntervalSinceNow: -90_000)
        try storage.remove(ids: [entry.id], now: old)
        try check(!storage.items.contains(where: { $0.id == entry.id }), "removal hides item")
        try check(fm.fileExists(atPath: storage.url(for: entry).path), "removed copies remain readable by drop targets")
        try storage.collectRetired(now: old.addingTimeInterval(86_400))
        try check(fm.fileExists(atPath: storage.url(for: entry).path), "copies survive the full 24-hour retention boundary")
        try storage.collectRetired(protecting: [entry.id])
        try check(fm.fileExists(atPath: storage.url(for: entry).path), "in-use retired copy survives expiry")
        try check(try TrayStorage(root: root).records.contains { $0.id == entry.id }, "protected retired record remains in the manifest")
        try storage.collectRetired()
        try check(!fm.fileExists(atPath: storage.url(for: entry).path), "expired retired copies cleaned")
        try check(fm.fileExists(atPath: storage.url(for: duplicate).path), "active copies are never auto-expired")
        try check(fm.fileExists(atPath: folder.path), "cleanup never deletes original folders")
        let failedRoot = base.appendingPathComponent("Failed")
        let failed = try TrayStorage(root: failedRoot)
        try fm.createDirectory(at: failedRoot.appendingPathComponent("shelf.json"), withIntermediateDirectories: true)
        do { _ = try failed.importFile(folder); fatalError("manifest write unexpectedly succeeded") }
        catch {
            try check(failed.items.isEmpty, "manifest write failure rolls back in-memory state")
            try check(try fm.contentsOfDirectory(atPath: failed.files.path).isEmpty, "manifest write failure removes incomplete copy")
        }
        let corrupt = base.appendingPathComponent("Corrupt")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let corruptData = Data("invalid JSON".utf8)
        try corruptData.write(to: corrupt.appendingPathComponent("shelf.json"))
        do { _ = try TrayStorage(root: corrupt); fatalError("corrupt manifest accepted") }
        catch { try check(try Data(contentsOf: corrupt.appendingPathComponent("shelf.json")) == corruptData, "corrupt manifest preserved for recovery") }
        try check(!TrayStorage.isSafeName("../outside") && !TrayStorage.isSafeName(".."), "path traversal names rejected")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([storage.url(for: duplicate) as NSURL, storage.url(for: folderEntry) as NSURL])
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try check(read?.count == 2, "native drag pasteboard carries multiple file URLs")
        try check(board.pasteboardItems?.allSatisfy { !$0.types.contains(.string) } == true, "outgoing files are not advertised as text paths")
        print("\(checks) checks passed")
    }
}
