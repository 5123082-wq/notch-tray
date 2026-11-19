// Save an edited system capture under its original name. GPL-3.0.
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotEdit: Codable {
    let cardID: UUID
    let revision: UUID
    let sourcePath: String
    let previousSourceID: String
    let replacementSourceID: String

    private var original: URL { URL(fileURLWithPath: sourcePath) }
    private static func stagingURL(for original: URL, revision: UUID) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(".notchtray-edit-\(revision.uuidString)")
    }
    private var staging: URL { Self.stagingURL(for: original, revision: revision) }

    static func encodedImage(_ png: Data, for original: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw TrayStorageError.invalidFile }
        if type as String == UTType.png.identifier { return png }
        let output = NSMutableData()
        guard [UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier].contains(type as String),
              let edited = CGImageSourceCreateWithData(png as CFData, nil),
              let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw TrayStorageError.screenshotEncoding
        }
        CGImageDestinationAddImageFromSource(destination, edited, 0,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TrayStorageError.screenshotEncoding }
        return output as Data
    }

    init(cardID: UUID, revision: UUID, source: ScreenshotFile, data: Data) throws {
        let staging = Self.stagingURL(for: source.url, revision: revision)
        try data.write(to: staging, options: .withoutOverwriting)
        do {
            // Retain Finder tags, permissions and the macOS screenshot marker.
            guard copyfile(source.url.path, staging.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: staging.path)
            guard let replacement = ScreenshotFile.inspect(staging) else { throw TrayStorageError.invalidFile }
            self.cardID = cardID
            self.revision = revision
            sourcePath = source.url.path
            previousSourceID = source.sourceID
            replacementSourceID = replacement.sourceID
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func publish(replacing source: ScreenshotFile) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: original, options: .forReplacing, error: &coordinationError) { target in
            result = Result {
                guard matchesSource(target, source),
                      ScreenshotFile.inspect(staging)?.sourceID == replacementSourceID else {
                    throw TrayStorageError.screenshotOriginalUnavailable
                }
                // Exchange directory entries atomically. The displaced file remains available
                // until the shelf manifest is durable, including across a process restart.
                try exchange(target, staging)
                if !matchesSource(staging, source) {
                    // An uncoordinated writer replaced the target between inspection and exchange.
                    if ScreenshotFile.inspect(target)?.sourceID == replacementSourceID { try exchange(target, staging) }
                    throw TrayStorageError.screenshotOriginalUnavailable
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TrayStorageError.screenshotOriginalUnavailable }
        try result.get()
    }

    private func matchesSource(_ url: URL, _ source: ScreenshotFile) -> Bool {
        guard let file = ScreenshotFile.inspect(url) else { return false }
        return file.identity == source.identity && file.modified == source.modified && file.size == source.size
    }

    private func exchange(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // Either side of the exchange proves its outcome, even if the user subsequently
    // renames the original. An offline volume leaves the decision pending.
    var published: Bool? {
        if let stagedID = ScreenshotFile.inspect(staging)?.sourceID {
            if stagedID == previousSourceID { return true }
            if stagedID == replacementSourceID { return false }
            return nil
        }
        let currentID = ScreenshotFile.inspect(original)?.sourceID
        if currentID == replacementSourceID { return true }
        if currentID == previousSourceID { return false }
        return nil
    }

    func apply(to entry: inout TrayEntry) {
        entry.name = original.lastPathComponent
        entry.imageRevision = revision
        entry.screenshotSourceID = replacementSourceID
        entry.screenshotSourcePath = sourcePath
    }

    func removeStaging(published: Bool) {
        if ScreenshotFile.inspect(staging)?.sourceID == (published ? previousSourceID : replacementSourceID) {
            try? FileManager.default.removeItem(at: staging)
        }
    }
}
