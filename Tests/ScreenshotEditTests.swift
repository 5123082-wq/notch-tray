// Source replacement, legacy file edits and interrupted saves on isolated files.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ScreenshotEditTests {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("save-original-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func check(_ label: String, _ test: @autoclosure () throws -> Bool) throws {
            guard try test() else { fatalError(label) }
            print("PASS: \(label)")
        }
        func image(_ type: UTType, white: CGFloat) -> Data {
            let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            bitmap.setFillColor(CGColor(gray: white, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let result = NSMutableData()
            let dest = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, bitmap.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(dest))
            return result as Data
        }
        let editedPNG = image(.png, white: 1)
        let sourcePNG = image(.png, white: 0)
        let root = base.appendingPathComponent("shelf")
        let store = try TrayStorage(root: root)
        let folder = base.appendingPathComponent("Снимки")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for type in [UTType.png, .jpeg, .tiff, .heic] {
            let original = folder.appendingPathComponent("Cнимок №1." + type.preferredFilenameExtension!)
            let originalBytes = image(type, white: 0)
            try originalBytes.write(to: original)
            let card = try store.importScreenshot(original, sourceID: ScreenshotFile.inspect(original)!.sourceID)!
            let saved = try store.saveEditedImage(editedPNG, for: card.id, expectedRevision: nil)
            let output = CGImageSourceCreateWithURL(original as CFURL, nil)!
            let bytes = try Data(contentsOf: original)
            try check("\(type.identifier) keeps its filename, format and dimensions with edited pixels",
                      saved.name == original.lastPathComponent && CGImageSourceGetType(output) as String? == type.identifier &&
                      CGImageSourceCreateImageAtIndex(output, 0, nil)?.width == 64 && bytes != originalBytes &&
                      (try Data(contentsOf: store.url(for: saved))) == bytes)
        }
        try check("Four saves leave exactly four files in the original folder", try fm.contentsOfDirectory(atPath: folder.path).count == 4)

        let ordinary = base.appendingPathComponent("Фото.jpg")
        let jpeg = image(.jpeg, white: 0)
        try jpeg.write(to: ordinary)
        let filesOnly = try TrayStorage(root: base.appendingPathComponent("files-only"))
        let file = try filesOnly.importFile(ordinary)
        let manifest = filesOnly.root.appendingPathComponent("shelf.json")
        let before = try Data(contentsOf: manifest)
        let editedFile = try filesOnly.saveEditedImage(editedPNG, for: file.id, expectedRevision: nil)
        try check("Ordinary files keep their original bytes and the shelf exports PNG",
                  try Data(contentsOf: ordinary) == jpeg && editedFile.name == "Фото.png" && Data(contentsOf: filesOnly.url(for: editedFile)) == editedPNG)
        try check("Copy-only edits still back up the v1 manifest before migrating to v2",
                  try Data(contentsOf: filesOnly.root.appendingPathComponent("shelf-before-image-editing.json")) == before &&
                  (JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])?["version"] as? Int == 2)

        let first = folder.appendingPathComponent("до.png")
        let renamed = folder.appendingPathComponent("после.png")
        try sourcePNG.write(to: first)
        let card = try store.importScreenshot(first, sourceID: ScreenshotFile.inspect(first)!.sourceID)!
        try fm.moveItem(at: first, to: renamed)
        try jpeg.write(to: first)
        let saved = try store.saveEditedImage(editedPNG, for: card.id, expectedRevision: nil)
        try check("A rename updates the matching file and preserves its former name's new occupant",
                  saved.screenshotSourcePath == renamed.path && (try Data(contentsOf: renamed)) == editedPNG && (try Data(contentsOf: first)) == jpeg)
        try fm.removeItem(at: renamed)
        try fm.createSymbolicLink(at: renamed, withDestinationURL: ordinary)
        do {
            _ = try store.saveEditedImage(sourcePNG, for: card.id, expectedRevision: saved.imageRevision)
            fatalError("An unrelated file was accepted as the capture")
        } catch TrayStorageError.screenshotOriginalUnavailable {
            try check("A missing original and a symlink leave the other file and the card intact",
                      try Data(contentsOf: ordinary) == jpeg && store.items.contains(saved))
        }

        // Recreate the durable state immediately on either side of the atomic exchange.
        for published in [false, true] {
            let recoveryRoot = base.appendingPathComponent("recover-\(published)")
            let initial = try TrayStorage(root: recoveryRoot)
            let original = folder.appendingPathComponent("interrupted-\(published).png")
            try sourcePNG.write(to: original)
            let snapshot = ScreenshotFile.inspect(original)!
            let entry = try initial.importScreenshot(original, sourceID: snapshot.sourceID)!
            let edit = try ScreenshotEdit(cardID: entry.id, revision: UUID(), source: snapshot, data: editedPNG)
            var revised = entry
            edit.apply(to: &revised)
            let copy = initial.url(for: revised)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try editedPNG.write(to: copy)
            let file = recoveryRoot.appendingPathComponent("shelf.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            json["pendingScreenshotEdits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([edit]))
            json["processedScreenshotSources"] = [snapshot.sourceID, edit.replacementSourceID]
            try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
            if published { try edit.publish(replacing: snapshot) }
            let restored = try TrayStorage(root: recoveryRoot)
            let expected = published ? revised : entry
            try check("Restart resolves an interrupted save (published = \(published))",
                      restored.items == [expected] && (try Data(contentsOf: original)) == (published ? editedPNG : sourcePNG) &&
                      (try Data(contentsOf: restored.url(for: expected))) == (published ? editedPNG : sourcePNG))
            try check("Resolved save releases its working files (published = \(published))",
                      try !fm.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasPrefix(".notchtray-edit-") }) &&
                      fm.fileExists(atPath: copy.path) == published)
        }
        print("Screenshot original save checks passed.")
    }
}
