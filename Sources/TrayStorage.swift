// Notch Tray — 2026-10-26. GPL-3.0. See THIRD_PARTY_NOTICES.md.
// Copy-backed shelf inspired by Lakr233/NotchDrop (MIT).
import Foundation

enum TrayCategory: String, Codable {
    case files, screenshots
}

struct TrayEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var added: Date
    var removed: Date?
    var category: TrayCategory = .files
    var screenshotSourceID: String?
    var screenshotSourcePath: String?
    // Edited images use immutable revisions. Previously handed-out URLs stay valid.
    var imageRevision: UUID?

    init(id: UUID, name: String, added: Date, removed: Date? = nil,
         category: TrayCategory = .files, screenshotSourceID: String? = nil) {
        self.id = id; self.name = name; self.added = added; self.removed = removed
        self.category = category; self.screenshotSourceID = screenshotSourceID
    }

    private enum CodingKeys: String, CodingKey { case id, name, added, removed, category, screenshotSourceID, screenshotSourcePath, imageRevision }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        added = try values.decode(Date.self, forKey: .added)
        removed = try values.decodeIfPresent(Date.self, forKey: .removed)
        category = try values.decodeIfPresent(TrayCategory.self, forKey: .category) ?? .files
        screenshotSourceID = try values.decodeIfPresent(String.self, forKey: .screenshotSourceID)
        screenshotSourcePath = try values.decodeIfPresent(String.self, forKey: .screenshotSourcePath)
        imageRevision = try values.decodeIfPresent(UUID.self, forKey: .imageRevision)
    }
}

private struct TrayManifest: Codable {
    var version = 1
    var entries: [TrayEntry]
    var processedScreenshotSources: Set<String>
    var screenshotFolderBaselines: Set<String>
    var pendingScreenshotEdits: [ScreenshotEdit]?
}

enum TrayStorageError: LocalizedError {
    case invalidManifest, invalidFile, missingFile(String), screenshotChanged, editConflict
    case screenshotOriginalUnavailable, screenshotEncoding
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Не удалось прочитать полку. Сохранённые файлы оставлены на месте."
        case .invalidFile: return "Этот объект не является локальным файлом."
        case .missingFile(let name): return "Файл «\(name)» недоступен."
        case .screenshotChanged: return "Скриншот ещё сохраняется. Добавление будет повторено."
        case .editConflict: return "Карточка уже удалена или изменена. Правки остались в редакторе."
        case .screenshotOriginalUnavailable: return "Не удалось найти исходный скриншот для замены. Проверьте, что файл и его папка доступны."
        case .screenshotEncoding: return "Не удалось записать правки в исходном формате скриншота."
        }
    }
}

/// Used exclusively on a serial I/O queue; tests use it synchronously.
final class TrayStorage {
    let root: URL
    private(set) var records: [TrayEntry] = []
    private(set) var processedScreenshotSources: Set<String> = []
    private(set) var screenshotFolderBaselines: Set<String> = []
    var items: [TrayEntry] { records.filter { $0.removed == nil } }
    private let fm = FileManager.default
    private var legacyManifestData: Data?
    private var manifestVersion = 1
    private var pendingScreenshotEdits: [ScreenshotEdit] = []
    private var manifest: URL { root.appendingPathComponent("shelf.json") }
    var files: URL { root.appendingPathComponent("Files", isDirectory: true) }
    var incoming: URL { root.appendingPathComponent("Incoming", isDirectory: true) }

    init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        if fm.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            let decoder = JSONDecoder()
            let decoded: [TrayEntry]
            if let document = try? decoder.decode(TrayManifest.self, from: data), [1, 2, 3].contains(document.version) {
                decoded = document.entries
                manifestVersion = document.version
                guard document.version >= 2 || decoded.allSatisfy({ $0.imageRevision == nil }) else {
                    throw TrayStorageError.invalidManifest
                }
                processedScreenshotSources = document.processedScreenshotSources
                screenshotFolderBaselines = document.screenshotFolderBaselines
                pendingScreenshotEdits = document.pendingScreenshotEdits ?? []
            } else if let legacy = try? decoder.decode([TrayEntry].self, from: data) {
                decoded = legacy
                legacyManifestData = data
            } else { throw TrayStorageError.invalidManifest }
            guard Set(decoded.map(\.id)).count == decoded.count,
                  decoded.allSatisfy({ Self.isSafeName($0.name) }) else {
                throw TrayStorageError.invalidManifest
            }
            records = decoded
            processedScreenshotSources.formUnion(decoded.compactMap(\.screenshotSourceID))
            recoverScreenshotEdits()
        }
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    func url(for entry: TrayEntry) -> URL {
        var directory = files.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        if let revision = entry.imageRevision {
            directory = directory.appendingPathComponent("Edits", isDirectory: true)
                .appendingPathComponent(revision.uuidString, isDirectory: true)
        }
        return directory.appendingPathComponent(entry.name)
    }

    private func commit(_ entries: [TrayEntry], sources: Set<String>? = nil, folders: Set<String>? = nil,
                        pending: [ScreenshotEdit]? = nil) throws {
        if let legacyManifestData {
            let backup = root.appendingPathComponent("shelf-v0.3-backup.json")
            if !fm.fileExists(atPath: backup.path) { try legacyManifestData.write(to: backup, options: .atomic) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let nextSources = sources ?? processedScreenshotSources
        let sourceVersion = nextSources.contains(where: { ScreenshotIdentity.persistentFileKey($0) != nil }) ? 3 : 1
        let version = max(manifestVersion, sourceVersion, entries.contains(where: { $0.imageRevision != nil }) ? 2 : 1)
        // Old apps reject v2 rather than silently showing an unedited file.
        if version >= 2, manifestVersion == 1, entries.contains(where: { $0.imageRevision != nil }), fm.fileExists(atPath: manifest.path) {
            let backup = root.appendingPathComponent("shelf-before-image-editing.json")
            if !fm.fileExists(atPath: backup.path) {
                try Data(contentsOf: manifest).write(to: backup, options: .atomic)
            }
        }
        // v1/v2 apps compare transient device numbers and would reimport v3 sources.
        if version == 3, manifestVersion < 3, fm.fileExists(atPath: manifest.path) {
            let backup = root.appendingPathComponent("shelf-before-screenshot-identity.json")
            if !fm.fileExists(atPath: backup.path) {
                try Data(contentsOf: manifest).write(to: backup, options: .atomic)
            }
        }
        let edits = pending ?? pendingScreenshotEdits
        let document = TrayManifest(version: version, entries: entries,
                                    processedScreenshotSources: nextSources,
                                    screenshotFolderBaselines: folders ?? screenshotFolderBaselines,
                                    pendingScreenshotEdits: edits.isEmpty ? nil : edits)
        try encoder.encode(document).write(to: manifest, options: .atomic)
        records = entries
        manifestVersion = version
        legacyManifestData = nil
        processedScreenshotSources = document.processedScreenshotSources
        screenshotFolderBaselines = document.screenshotFolderBaselines
        pendingScreenshotEdits = edits
    }

    /// Old journals did not store the volume UUID. Match inode + birth time only
    /// in a previously observed folder, before the monitor considers any imports.
    /// Retain the old IDs so a temporarily absent original can migrate when it returns.
    func migrateScreenshotSources(in folderID: String, identities: [ScreenshotIdentity]) throws {
        guard screenshotFolderBaselines.contains(folderID) else { return }
        let legacyKeys = Set(processedScreenshotSources.compactMap(ScreenshotIdentity.legacyFileKey))
        let migratedKeys = Set(processedScreenshotSources.compactMap(ScreenshotIdentity.persistentFileKey))
        // Once assigned to a persistent volume, an old key must not match another volume.
        let pendingKeys = legacyKeys.subtracting(migratedKeys)
        let migrated = Set(identities.filter { pendingKeys.contains($0.fileKey) }.map(\.sourceID))
        guard !migrated.isEmpty else { return }
        try commit(records, sources: processedScreenshotSources.union(migrated))
    }

    @discardableResult
    func saveEditedImage(_ data: Data, for id: UUID, expectedRevision: UUID?, screenshotFolder: URL? = nil) throws -> TrayEntry {
        if pendingScreenshotEdits.contains(where: { $0.cardID == id }) {
            recoverScreenshotEdits()
            guard !pendingScreenshotEdits.contains(where: { $0.cardID == id }) else { throw TrayStorageError.screenshotOriginalUnavailable }
        }
        guard let index = records.firstIndex(where: { $0.id == id && $0.removed == nil }),
              records[index].imageRevision == expectedRevision else { throw TrayStorageError.editConflict }
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw TrayStorageError.invalidFile }
        var updated = records[index]
        let revision = UUID()
        let scoped = screenshotFolder?.startAccessingSecurityScopedResource() == true
        defer { if scoped { screenshotFolder?.stopAccessingSecurityScopedResource() } }
        let original = updated.category == .screenshots ? try originalScreenshot(for: updated, folder: screenshotFolder) : nil
        let bytes = try original.map { try ScreenshotEdit.encodedImage(data, for: $0.url) } ?? data
        updated.imageRevision = revision
        updated.name = original?.url.lastPathComponent ?? (updated.name as NSString).deletingPathExtension + ".png"
        let destination = url(for: updated)
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try bytes.write(to: destination, options: .atomic)
            if let original {
                let edit = try ScreenshotEdit(cardID: id, revision: revision, source: original, data: bytes)
                do {
                    // Register both identities before the monitor can see the replacement.
                    try commit(records, sources: processedScreenshotSources.union([original.sourceID, edit.replacementSourceID]),
                               pending: pendingScreenshotEdits + [edit])
                } catch {
                    edit.removeStaging(published: false)
                    throw error
                }
                do { try edit.publish(replacing: original) }
                catch {
                    if let published = edit.published {
                        finishScreenshotEdit(edit, at: index, published: published)
                        if published { return records[index] }
                    }
                    throw error
                }
                finishScreenshotEdit(edit, at: index, published: true)
                return records[index]
            }
            var next = records
            next[index] = updated
            try commit(next)
            return updated
        } catch {
            if !pendingScreenshotEdits.contains(where: { $0.revision == revision }) {
                try? fm.removeItem(at: directory)
            }
            throw error
        }
    }

    private func originalScreenshot(for entry: TrayEntry, folder: URL?) throws -> ScreenshotFile {
        guard let sourceID = entry.screenshotSourceID else { throw TrayStorageError.screenshotOriginalUnavailable }
        let savedURL = entry.screenshotSourcePath.map { URL(fileURLWithPath: $0) }
        if let savedURL, let file = ScreenshotFile.inspect(savedURL), file.sourceID == sourceID { return file }

        // Older cards only have an identity. Search the previously watched folders,
        // including when the capture has since been renamed. Never select by name alone.
        var folders = screenshotFolderBaselines
        if let savedURL { folders.insert(savedURL.deletingLastPathComponent().path) }
        if let folder { folders.insert(folder.path) }
        let legacyKey = ScreenshotIdentity.legacyFileKey(sourceID)
        let migratedIDs = legacyKey.map { key in processedScreenshotSources.filter { ScreenshotIdentity.persistentFileKey($0) == key } } ?? []
        var legacyMatch: ScreenshotFile?
        for path in folders {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                   options: [.skipsHiddenFiles])
            for url in urls ?? [] {
                guard let file = ScreenshotFile.inspect(url) else { continue }
                if file.sourceID == sourceID { return file }
                if file.identity.fileKey == legacyKey, screenshotFolderBaselines.contains(path),
                   migratedIDs.isEmpty || migratedIDs.contains(file.sourceID) {
                    if let existing = legacyMatch, existing.url != file.url { throw TrayStorageError.screenshotOriginalUnavailable }
                    legacyMatch = file
                }
            }
        }
        guard let legacyMatch else { throw TrayStorageError.screenshotOriginalUnavailable }
        return legacyMatch
    }

    @discardableResult
    func recoverScreenshotEdits() -> Bool {
        var changed = false
        for edit in pendingScreenshotEdits {
            if let index = records.firstIndex(where: { $0.id == edit.cardID }), let published = edit.published {
                changed = changed || (published && records[index].imageRevision != edit.revision)
                finishScreenshotEdit(edit, at: index, published: published)
            }
        }
        return changed
    }

    private func finishScreenshotEdit(_ edit: ScreenshotEdit, at index: Int, published: Bool) {
        var revised = records[index]
        edit.apply(to: &revised)
        if published { records[index] = revised }
        // The prepared manifest and the exchanged names already determine the outcome.
        // If this final write fails, reopening can finish it without writing to the original.
        do { try commit(records, pending: pendingScreenshotEdits.filter { $0.revision != edit.revision }) }
        catch { return }
        edit.removeStaging(published: published)
        if !published { try? fm.removeItem(at: url(for: revised).deletingLastPathComponent()) }
    }

    /// Baselines are durable and independent of visible/retired entries.
    /// Enabling capture or choosing a different folder excludes its existing archive.
    func baselineScreenshotFolder(_ folderID: String, sourceIDs: Set<String>, force: Bool = false) throws {
        guard force || !screenshotFolderBaselines.contains(folderID) else { return }
        try commit(records, sources: processedScreenshotSources.union(sourceIDs),
                   folders: screenshotFolderBaselines.union([folderID]))
    }

    @discardableResult
    func importScreenshot(_ source: URL, sourceID: String, validateCopy: ((URL) -> Bool)? = nil) throws -> TrayEntry? {
        guard !processedScreenshotSources.contains(sourceID) else { return nil }
        return try importCopy(source, category: .screenshots, sourceID: sourceID, validateCopy: validateCopy)
    }

    @discardableResult
    func importFile(_ source: URL) throws -> TrayEntry {
        try importCopy(source, category: .files, sourceID: nil)
    }

    private func importCopy(_ source: URL, category: TrayCategory, sourceID: String?, validateCopy: ((URL) -> Bool)? = nil) throws -> TrayEntry {
        guard source.isFileURL, Self.isSafeName(source.lastPathComponent) else { throw TrayStorageError.invalidFile }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let resolved = source.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolved.path) else { throw TrayStorageError.missingFile(source.lastPathComponent) }
        var entry = TrayEntry(id: UUID(), name: source.lastPathComponent, added: Date(),
                              category: category, screenshotSourceID: sourceID)
        if category == .screenshots { entry.screenshotSourcePath = source.standardizedFileURL.path }
        let destination = url(for: entry)
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: resolved, to: destination)
            if let validateCopy, !validateCopy(destination) { throw TrayStorageError.screenshotChanged }
            let sources = sourceID.map { processedScreenshotSources.union([$0]) }
            try commit(records + [entry], sources: sources)
            return entry
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// Retain removed copies for 24h, so a drop target can finish reading a URL.
    /// Original files are never moved or removed.
    func remove(ids: Set<UUID>, now: Date = Date()) throws {
        try commit(records.map { entry in
            var updated = entry
            if ids.contains(entry.id), entry.removed == nil { updated.removed = now }
            return updated
        })
    }

    func collectRetired(now: Date = Date(), protecting protectedIDs: Set<UUID> = []) throws {
        let expired = records.filter { entry in
            !protectedIDs.contains(entry.id) && (entry.removed.map { now.timeIntervalSince($0) > 86_400 } ?? false)
                && !pendingScreenshotEdits.contains(where: { $0.cardID == entry.id })
        }
        guard !expired.isEmpty else { return }
        // Keep the record if its deletion fails. Retry on a later launch.
        var deleted = Set<UUID>()
        for entry in expired {
            let directory = files.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            deleted.insert(entry.id)
        }
        try commit(records.filter { !deleted.contains($0.id) })
    }
}
