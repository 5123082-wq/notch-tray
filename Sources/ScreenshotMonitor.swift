// Notch Tray — GPL-3.0.
import Foundation
import ImageIO
import CoreServices
import Darwin

struct ScreenshotMonitorStatus: Equatable {
    var folder: URL
    var isEnabled: Bool
    var issue: String?
}

struct ScreenshotFile: Equatable {
    let url: URL
    let identity: ScreenshotIdentity
    var sourceID: String { identity.sourceID }
    let size: Int64
    let modified: Date

    /// Persistent volume UUID + inode + creation time survives reboots and renames.
    static func inspect(_ url: URL) -> ScreenshotFile? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .volumeUUIDStringKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let volumeUUID = values.volumeUUIDString, UUID(uuidString: volumeUUID) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        let identity = ScreenshotIdentity(volumeUUID: volumeUUID, inode: inode.uint64Value, created: created)
        return ScreenshotFile(url: url, identity: identity, size: size.int64Value, modified: modified)
    }

    static func hasScreenshotMetadata(_ url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let length = url.path.withCString { path in key.withCString { getxattr(path, $0, nil, 0, 0, XATTR_NOFOLLOW) } }
        if length > 0, length < 65_536 {
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { buffer in
                url.path.withCString { path in key.withCString { getxattr(path, $0, buffer.baseAddress, length, 0, XATTR_NOFOLLOW) } }
            }
            if read == length,
               let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let flag = value as? NSNumber { return flag.boolValue }
        }
        // Spotlight is a fallback only: the extended attribute works before indexing.
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber else { return false }
        return value.boolValue
    }

    static func isCompleteImage(_ url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatus(image) == .statusComplete,
              let decoded = CGImageSourceCreateImageAtIndex(image, 0, options),
              decoded.width > 0, decoded.height > 0 else { return false }
        return CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete
    }
}

/// Watches one directory. All mutable state and storage calls run on `queue`.
/// Callbacks are delivered to main; directory events are coalesced and a slow
/// reconciliation catches delayed metadata, sleep/wake and system-folder changes.
final class ScreenshotMonitor {
    private let storage: TrayStorage
    private let queue: DispatchQueue
    private let onUpdate: ([TrayEntry], ScreenshotMonitorStatus) -> Void
    private var settings = ScreenshotSettings()
    private var folder: URL?
    private var scopeActive = false
    private var directorySource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private var observations: [String: (file: ScreenshotFile, since: Date)] = [:]
    private var lastStatus: ScreenshotMonitorStatus?
    private var running = false
    private var forceBaseline = false

    init(storage: TrayStorage, queue: DispatchQueue,
         onUpdate: @escaping ([TrayEntry], ScreenshotMonitorStatus) -> Void) {
        self.storage = storage; self.queue = queue; self.onUpdate = onUpdate
    }

    func start(settings: ScreenshotSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = settings
            self.running = true
            self.installTimer()
            self.reconcile()
        }
    }

    func update(settings: ScreenshotSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = self.settings.automaticImport
            let folderChanged = self.settings.customFolderPath != settings.customFolderPath
            self.settings = settings
            if (!wasEnabled && settings.automaticImport) || folderChanged { self.forceBaseline = true }
            self.reconcile()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        running = false
        pendingScan?.cancel(); pendingScan = nil
        timer?.cancel(); timer = nil
        closeDirectory()
    }

    private func installTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        source.setEventHandler { [weak self] in self?.reconcile() }
        source.resume()
        timer = source
    }

    private func closeDirectory() {
        directorySource?.cancel(); directorySource = nil
        if scopeActive, let folder { folder.stopAccessingSecurityScopedResource() }
        scopeActive = false
        observations.removeAll()
    }

    private func scheduleScan(after delay: Double = 0.35) {
        guard pendingScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScan = nil
            self.reconcile()
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publish(folder: URL, issue: String?, imported: Bool = false) {
        let status = ScreenshotMonitorStatus(folder: folder, isEnabled: settings.automaticImport, issue: issue)
        guard imported || status != lastStatus else { return }
        lastStatus = status
        let snapshot = storage.items
        DispatchQueue.main.async { [onUpdate] in onUpdate(snapshot, status) }
    }

    private func reconcile() {
        guard running else { return }
        let desired = settings.resolvedFolder().standardizedFileURL
        guard settings.automaticImport else {
            closeDirectory(); folder = desired
            publish(folder: desired, issue: nil)
            return
        }
        if let folder, folder != desired {
            closeDirectory()
            forceBaseline = true
        }
        folder = desired
        if directorySource == nil {
            scopeActive = desired.startAccessingSecurityScopedResource()
            let descriptor = open(desired.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if scopeActive { desired.stopAccessingSecurityScopedResource(); scopeActive = false }
                publish(folder: desired, issue: "Нет доступа к папке скриншотов. Выберите доступную папку в настройках: \(desired.path)")
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if let data = self.directorySource?.data, !data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.closeDirectory()
                }
                self.scheduleScan()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySource = source
        }
        do {
            let recoveredEdits = storage.recoverScreenshotEdits()
            let volume = try desired.resourceValues(forKeys: [.volumeUUIDStringKey])
            guard let uuid = volume.volumeUUIDString, UUID(uuidString: uuid) != nil else {
                publish(folder: desired, issue: "Эта папка не поддерживает надёжное запоминание скриншотов. Выберите папку на локальном диске.")
                return
            }
            let urls = try FileManager.default.contentsOfDirectory(at: desired,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            let files = urls.compactMap(ScreenshotFile.inspect)
            try storage.migrateScreenshotSources(in: desired.path, identities: files.map(\.identity))
            try storage.baselineScreenshotFolder(desired.path, sourceIDs: Set(files.map(\.sourceID)), force: forceBaseline)
            forceBaseline = false
            let existingIDs = Set(files.map(\.sourceID))
            observations = observations.filter { existingIDs.contains($0.key) }
            var imported = false
            var needsRetry = false
            var importIssue: String?
            for file in files.sorted(by: { $0.modified < $1.modified }) {
                guard !storage.processedScreenshotSources.contains(file.sourceID), file.size > 0 else { continue }
                let now = Date()
                guard let previous = observations[file.sourceID], previous.file == file,
                      now.timeIntervalSince(previous.since) >= 0.7 else {
                    if observations[file.sourceID]?.file != file { observations[file.sourceID] = (file, now) }
                    needsRetry = true
                    continue
                }
                guard ScreenshotFile.hasScreenshotMetadata(file.url), ScreenshotFile.isCompleteImage(file.url) else { continue }
                // Recheck after decoding: do not copy a file that changed while being inspected.
                guard ScreenshotFile.inspect(file.url) == file else { needsRetry = true; continue }
                do {
                    if try storage.importScreenshot(file.url, sourceID: file.sourceID, validateCopy: { copy in
                        ScreenshotFile.isCompleteImage(copy) && ScreenshotFile.inspect(file.url) == file
                    }) != nil { imported = true }
                    observations.removeValue(forKey: file.sourceID)
                } catch TrayStorageError.screenshotChanged {
                    observations.removeValue(forKey: file.sourceID)
                    needsRetry = true
                } catch { importIssue = "Не удалось добавить скриншот: \(error.localizedDescription)" }
            }
            let targetIssue = settings.customFolderPath == nil ? ScreenshotFolder.systemTargetIssue() : nil
            publish(folder: desired, issue: importIssue ?? targetIssue, imported: recoveredEdits || imported)
            if needsRetry { scheduleScan(after: 0.8) }
        } catch {
            publish(folder: desired, issue: "Не удалось прочитать папку скриншотов: \(error.localizedDescription)")
        }
    }

    deinit {
        pendingScan?.cancel()
        timer?.cancel()
        directorySource?.cancel()
        if scopeActive, let folder { folder.stopAccessingSecurityScopedResource() }
    }
}
