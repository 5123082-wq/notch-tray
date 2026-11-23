// Notch Tray — GPL-3.0. 2026-10-26.
import AppKit
import QuartzCore

enum ShelfSection: String, Hashable { case files, screenshots }

final class TrayController: NSObject {
    let storage: TrayStorage
    let io = DispatchQueue(label: "local.notchtray.storage", qos: .userInitiated)
    let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.notchtray.promises"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    var geometry: NotchGeometry
    let panel: NotchPanel
    let view: ShelfView
    let dragObserver = DragObserver()
    private let shortcutActions = ShortcutActionService()
    private var statusItem: NSStatusItem!
    private var releaseUpdates: ReleaseUpdates?
    private var closeWork: DispatchWorkItem?
    private var dragReleaseWork: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var motion = TrayMotion()
    private var screenObserver: NSObjectProtocol?
    private var cleanupTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cleanupPending = false
    private var retainedPromiseReceivers: [UUID: NSFilePromiseReceiver] = [:]
    private var promiseRemaining: [UUID: Int] = [:]
    private var userScreenID: UInt32?
    private let screenshotSettingsStore: ScreenshotSettingsStore
    private var screenshotMonitor: ScreenshotMonitor?
    private var screenshotMonitorStatus: ScreenshotMonitorStatus?
    private var sectionSelections: [ShelfSection: Set<UUID>] = [:]
    private var sectionAnchors: [ShelfSection: UUID] = [:]
    private var previewIDs: [UUID] = []
    private var previewID: UUID?
    private(set) var imageEditors: [UUID: ImageEditor] = [:]
    private var loadingEditors = Set<UUID>()
    private var closingEditorsForTermination = false
    private(set) var activeSection: ShelfSection = .files
    var entries: [TrayEntry]
    func entries(in section: ShelfSection) -> [TrayEntry] {
        entries.filter { $0.category == (section == .files ? .files : .screenshots) }
    }
    func selectedIDs(in section: ShelfSection) -> Set<UUID> {
        let ids = section == activeSection ? selection : (sectionSelections[section] ?? [])
        return ids.intersection(Set(entries(in: section).map(\.id)))
    }
    var visibleEntries: [TrayEntry] {
        entries.filter { $0.category == (activeSection == .files ? .files : .screenshots) }
    }
    var screenshotCount: Int { entries.filter { $0.category == .screenshots }.count }
    var screenshotSettings: ScreenshotSettings { screenshotSettingsStore.settings }
    var screenshotFolder: URL {
        screenshotMonitorStatus?.folder ?? screenshotSettings.resolvedFolder()
    }
    var screenshotStatusText: String {
        if !screenshotSettings.automaticImport { return "Автоматическое добавление выключено" }
        if let issue = screenshotMonitorStatus?.issue { return issue }
        return ""
    }
    var selection = Set<UUID>()
    var anchor: UUID?
    var isExpanded = false
    var isPinned = false
    var incomingDrag = false { didSet { view.updateState() } }
    var isDraggingOut = false { didSet { view.updateState() } }
    private(set) var externalDragActive = false {
        didSet { if externalDragActive != oldValue { view.updateState() } }
    }
    var choosingFiles = false
    private var showingShelfMenu = false
    private var sendingShortcut = false
    var canSwitchSections: Bool {
        !isDraggingOut && !incomingDrag && !externalDragActive &&
        !choosingFiles && !showingShelfMenu && !sendingShortcut && imageEditors.isEmpty
    }
    var busy = 0 { didSet { view.updateState() } }
    var message: String?
    var hasError = false
    var statusText: String {
        if busy > 0 { return "Добавление: \(busy)…" }
        if let message { return message }
        if let version = releaseUpdates?.availableVersion { return "В меню полки доступна версия " + version }
        if visibleEntries.isEmpty { return activeSection == .files ? "Файлы всегда под рукой" : "Новые скриншоты появятся здесь" }
        return "\(visibleEntries.count) на полке · ⌘ для выбора нескольких"
    }

    init(root: URL, monitorScreenshots: Bool = false, cleanupInterval: TimeInterval = 60) throws {
        storage = try TrayStorage(root: root)
        screenshotSettingsStore = try ScreenshotSettingsStore(root: root)
        entries = storage.items
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            throw NSError(domain: "NotchTray", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден экран."])
        }
        geometry = NotchGeometry(screen: screen)
        panel = NotchPanel(frame: geometry.frame(open: false))
        view = ShelfView(frame: NSRect(origin: .zero, size: geometry.closedSize))
        super.init()
        view.controller = self
        panel.contentView = view
        panel.title = "Notch Tray"
        view.reload()
        makeMenu()
        dragObserver.onMove = { [weak self] point, isContent in
            guard let self, isContent, !self.isDraggingOut else { return }
            self.armExternalDrag()
            if self.geometry.trigger.contains(point) { self.expand() }
        }
        dragObserver.onRelease = { [weak self] in
            guard let self else { return }
            // Let AppKit deliver perform/conclude before restoring normal hit testing.
            self.dragReleaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finishExternalDrag() }
            self.dragReleaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        dragObserver.onMouseDown = { [weak self] point in
            guard let self else { return }
            self.view.updateHover(at: point)
            if self.geometry.trigger.contains(point), !self.panel.isPreviewing { self.showPinned() }
            else if self.isPinned, !self.panel.isPreviewing, !self.geometry.frame(open: true).contains(point), !self.choosingFiles { self.collapse() }
        }
        dragObserver.onHover = { [weak self] point in
            guard let self else { return }
            self.view.updateHover(at: point)
            if self.geometry.trigger.contains(point) { self.expand() }
            else if self.isExpanded {
                if self.geometry.frame(open: true).insetBy(dx: -8, dy: -8).contains(point) {
                    self.closeWork?.cancel()
                    self.closeWork = nil
                } else { self.scheduleCollapse() }
            }
        }
        dragObserver.start()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.updateScreen() }
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.collectRetiredCopies()
        }
        timer.tolerance = min(5, cleanupInterval / 10)
        cleanupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.collectRetiredCopies() }
        collectRetiredCopies()
        if monitorScreenshots {
            let monitor = ScreenshotMonitor(storage: storage, queue: io) { [weak self] snapshot, status in
                guard let self else { return }
                self.screenshotMonitorStatus = status
                self.applySnapshot(snapshot)
                self.makeMenu()
            }
            screenshotMonitor = monitor
            monitor.start(settings: screenshotSettings)
        }
    }

    // Capture usage on the main thread, then delete on the serial storage queue.
    // Protect every displayed entry too: a queued removal may not yet have reached
    // the UI, and the user can start preview/edit/drag before this cleanup executes.
    func collectRetiredCopies() {
        precondition(Thread.isMainThread)
        guard !cleanupPending, !isDraggingOut, !incomingDrag, !externalDragActive else { return }
        var protectedIDs = Set(entries.map(\.id))
        protectedIDs.formUnion(imageEditors.keys)
        protectedIDs.formUnion(loadingEditors)
        if let previewID { protectedIDs.insert(previewID) }
        let protectedSnapshot = protectedIDs
        cleanupPending = true
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.storage.collectRetired(protecting: protectedSnapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cleanupPending = false
                if case .failure(let error) = result {
                    self.report("Не удалось очистить старые копии: \(error.localizedDescription)")
                }
            }
        }
    }

    func url(for entry: TrayEntry) -> URL { storage.url(for: entry) }
    func switchSection(_ section: ShelfSection) {
        guard section != activeSection, canSwitchSections else { return }
        panel.closePreview()
        sectionSelections[activeSection] = selection
        sectionAnchors[activeSection] = anchor
        activeSection = section
        let valid = Set(visibleEntries.map(\.id))
        selection = (sectionSelections[section] ?? []).intersection(valid)
        anchor = sectionAnchors[section].flatMap { valid.contains($0) ? $0 : nil }
        message = nil
        hasError = false
        view.reload()
    }
    private func applySnapshot(_ snapshot: [TrayEntry]) {
        entries = snapshot
        selection.formIntersection(Set(visibleEntries.map(\.id)))
        // Keep the drag source view alive until AppKit reports completion.
        if !isDraggingOut { view.reload() }
        updatePreview()
    }
    func saveScreenshotSettings(_ settings: ScreenshotSettings) throws {
        try screenshotSettingsStore.save(settings)
        screenshotMonitorStatus = nil
        screenshotMonitor?.update(settings: settings)
        view.updateState()
        makeMenu()
    }
    func expand() {
        guard !sendingShortcut, imageEditors.isEmpty, !closingEditorsForTermination else { return }
        closeWork?.cancel()
        closeWork = nil
        guard !isExpanded else { return }
        isExpanded = true
        view.updateState()
        resize(animated: true)
        panel.orderFrontRegardless()
    }
    func collapse() {
        guard isExpanded, !isDraggingOut, !incomingDrag, !choosingFiles, !showingShelfMenu else { return }
        closeWork?.cancel()
        closeWork = nil
        isPinned = false
        isExpanded = false
        panel.closePreview()
        view.updateState()
        resize(animated: true)
    }
    private func resize(animated: Bool) {
        motion.retarget(open: isExpanded)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            motion.finish()
            finishMotion()
            return
        }
        // Keep one stable window during the reveal. Core Animation clips the
        // fixed-width content; WindowServer never resizes it on every frame.
        panel.ignoresMouseEvents = false
        panel.setFrame(geometry.frame(open: true), display: true)
        view.layoutSubtreeIfNeeded()
        view.present(expansion: motion.value)
        guard displayLink == nil else { return }
        lastFrameTime = nil
        let link = panel.displayLink(target: self, selector: #selector(animateFrame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func animateFrame(_ link: CADisplayLink) {
        let elapsed = lastFrameTime.map { link.timestamp - $0 } ?? (1.0 / 120.0)
        lastFrameTime = link.timestamp
        motion.advance(seconds: min(0.05, max(0, elapsed)))
        view.present(expansion: motion.value)
        if motion.settled { motion.finish(); finishMotion() }
    }
    private func finishMotion() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
        view.present(expansion: motion.value)
        panel.setFrame(geometry.frame(open: isExpanded), display: true)
        view.layoutSubtreeIfNeeded()
        view.present(expansion: motion.value)
        // The idle panel has zero visible pixels and cannot eat menu-bar clicks.
        // The mouse-only observer still detects entry into its exact notch area.
        panel.ignoresMouseEvents = !isExpanded && !externalDragActive
        if !isExpanded, panel.isKeyWindow {
            // Ordering the invisible panel out releases keyboard focus after preview.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
    func scheduleCollapse(delay: Double = 0.3) {
        guard isExpanded, closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard !self.isPinned, !self.showingShelfMenu, !self.geometry.frame(open: true).insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation), self.busy == 0 else { return }
            self.collapse()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func endIncomingDrag() {
        incomingDrag = false
        scheduleCollapse()
    }
    func armExternalDrag() {
        guard imageEditors.isEmpty else { return }
        dragReleaseWork?.cancel()
        dragReleaseWork = nil
        externalDragActive = true
        // Arm the existing notch-sized window before the pointer reaches it.
        // Ordinary idle mouse clicks still pass through to the menu bar.
        panel.ignoresMouseEvents = false
    }
    func finishExternalDrag() {
        dragReleaseWork?.cancel()
        dragReleaseWork = nil
        externalDragActive = false
        incomingDrag = false
        panel.ignoresMouseEvents = !isExpanded
        scheduleCollapse()
    }
    func outgoingFinished(success: Bool, ids: Set<UUID> = []) {
        isDraggingOut = false
        let screenshots = Set(entries.filter { ids.contains($0.id) && $0.category == .screenshots }.map(\.id))
        if success, screenshotSettings.removeAfterDrag, !screenshots.isEmpty {
            remove(screenshots, successMessage: "Скриншоты переданы · оригиналы сохранены")
        }
        message = success ? "Файлы переданы" : "Перетаскивание отменено"
        hasError = false
        view.reload()
        scheduleCollapse(delay: 1.1)
    }
    func report(_ text: String) {
        message = text
        hasError = true
        view.updateState()
        view.subtitle.toolTip = text
    }
    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        panel.closePreview()
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let anchor,
                  let first = visibleEntries.firstIndex(where: { $0.id == anchor }), let last = visibleEntries.firstIndex(where: { $0.id == id }) {
            selection.formUnion(visibleEntries[min(first, last)...max(first, last)].map(\.id))
        } else if !selection.contains(id) { selection = [id]; anchor = id }
        view.updateSelection()
    }
    func selectOnly(_ id: UUID) { selection = [id]; anchor = id; view.updateSelection() }
    @objc func selectAll() {
        panel.closePreview()
        selection = Set(visibleEntries.map(\.id))
        view.updateSelection()
    }
    func dragItems(for id: UUID) -> [TrayEntry] {
        if !selection.contains(id) { selectOnly(id) }
        return visibleEntries.filter { selection.contains($0.id) }
    }

    @discardableResult
    func accept(_ board: NSPasteboard) -> Bool {
        incomingDrag = false
        // Manual file drops always belong to Files, even over the screenshots tab.
        let wasExternal = externalDragActive
        externalDragActive = false
        switchSection(.files)
        externalDragActive = wasExternal
        message = nil
        hasError = false
        if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            for receiver in promises { acceptPromise(receiver) }
            return true
        }
        let urls = DropInput.fileURLs(board)
        if !urls.isEmpty { importURLs(urls); return true }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = board.data(forType: type) {
                let directory = storage.incoming.appendingPathComponent(UUID().uuidString)
                let file = directory.appendingPathComponent("Изображение.\(ext)")
                busy += 1
                io.async { [weak self] in
                    guard let self else { return }
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try data.write(to: file, options: .atomic)
                        _ = try self.storage.importFile(file)
                        try? FileManager.default.removeItem(at: directory)
                        self.finishImport(error: nil)
                    } catch { self.finishImport(error: error) }
                }
                return true
            }
        }
        report("Перетащи файл из Finder или изображение из приложения.")
        return false
    }
    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switchSection(.files)
        expand()
        message = nil
        hasError = false
        busy += urls.count
        // Keep source permissions alive throughout the asynchronous copy.
        let permissions = urls.map { $0.startAccessingSecurityScopedResource() }
        io.async { [weak self] in
            guard let self else { return }
            for (index, url) in urls.enumerated() {
                do { _ = try self.storage.importFile(url); self.finishImport(error: nil) }
                catch { self.finishImport(error: error) }
                if permissions[index] { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
    private func acceptPromise(_ receiver: NSFilePromiseReceiver) {
        let id = UUID()
        let directory = storage.incoming.appendingPathComponent(id.uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { report(error.localizedDescription); return }
        let count = max(1, receiver.fileNames.count)
        retainedPromiseReceivers[id] = receiver
        promiseRemaining[id] = count
        busy += count
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
            guard let self else { return }
            self.io.async {
                var resultError = error
                if error == nil {
                    do { _ = try self.storage.importFile(url); try? FileManager.default.removeItem(at: url) }
                    catch { resultError = error }
                }
                self.finishImport(error: resultError)
                DispatchQueue.main.async {
                    let remaining = (self.promiseRemaining[id] ?? 1) - 1
                    if remaining <= 0 {
                        self.retainedPromiseReceivers.removeValue(forKey: id)
                        self.promiseRemaining.removeValue(forKey: id)
                        self.io.async { try? FileManager.default.removeItem(at: directory) }
                    } else { self.promiseRemaining[id] = remaining }
                }
            }
        }
    }
    // Called only on the serial storage queue.
    private func finishImport(error: Error?) {
        let snapshot = storage.items
        DispatchQueue.main.async {
            self.busy = max(0, self.busy - 1)
            if let error { self.report(error.localizedDescription) }
            else if !self.hasError { self.message = "Добавлено · можно переключить приложение" }
            self.applySnapshot(snapshot)
            self.scheduleCollapse(delay: 2)
        }
    }
    @objc func removeSelected() {
        guard !isDraggingOut else { return }
        remove(selection)
    }
    func removeEntry(_ id: UUID) {
        guard !isDraggingOut, !incomingDrag, !externalDragActive else { return }
        remove([id])
    }
    @objc func clearShelf() { guard !isDraggingOut else { return }; remove(Set(visibleEntries.map(\.id))) }
    private func remove(_ ids: Set<UUID>, successMessage: String? = nil) {
        guard !ids.isEmpty else { return }
        busy += 1
        io.async { [weak self] in
            guard let self else { return }
            do {
                try self.storage.remove(ids: ids)
                let snapshot = self.storage.items
                DispatchQueue.main.async {
                    self.busy = max(0, self.busy - 1)
                    self.selection.subtract(ids)
                    self.message = successMessage
                    self.hasError = false
                    self.applySnapshot(snapshot)
                }
            } catch { DispatchQueue.main.async { self.busy = max(0, self.busy - 1); self.report(error.localizedDescription) } }
        }
    }
    func open(_ entry: TrayEntry) { NSWorkspace.shared.open(url(for: entry)); collapse() }
    func previewSelection() {
        guard isExpanded, canSwitchSections else { return }
        if panel.isPreviewing { panel.closePreview(); return }
        let entries = visibleEntries
        let selected = entries.filter { selection.contains($0.id) }
        guard let first = selected.first else { return }
        previewIDs = (selected.count > 1 ? selected : entries).map(\.id)
        previewID = first.id
        showPinned()
        updatePreview()
    }

    func updatePreview(step: Int = 0) {
        guard let previewID, let index = previewIDs.firstIndex(of: previewID) else { return }
        let entries = Dictionary(uniqueKeysWithValues: visibleEntries.map { ($0.id, $0) })
        let available = previewIDs.enumerated().compactMap { index, id -> (index: Int, entry: TrayEntry)? in
            guard let entry = entries[id], FileManager.default.fileExists(atPath: url(for: entry).path) else { return nil }
            return (index, entry)
        }
        let previous = available.last { $0.index < index }
        let next = available.first { $0.index > index }
        let current = available.first { $0.index == index }
        let requested = step < 0 ? previous : step > 0 ? next : current
        guard let entry = (requested ?? current ?? next ?? previous)?.entry else {
            let name = entries[previewID]?.name
            panel.closePreview()
            if let name { report("Файл «\(name)» недоступен.") }
            return
        }
        previewIDs = available.map { $0.entry.id }
        self.previewID = entry.id
        selectOnly(entry.id)
        view.revealCard(entry.id)
        let url = url(for: entry)
        let edit: (() -> Void)? = canEdit(entry) ? { [weak self] in self?.editImage(entry.id) } : nil
        panel.showPreview(of: url, in: geometry.previewFrame, edit: edit)
    }

    @discardableResult
    func endPreview() -> Bool {
        guard let previewID else { return false }
        self.previewID = nil
        previewIDs = []
        if visibleEntries.contains(where: { $0.id == previewID }), selection != [previewID] {
            selectOnly(previewID)
        }
        return true
    }

    func canEdit(_ entry: TrayEntry) -> Bool {
        EditableImage.supports(url(for: entry))
    }

    func editImage(_ id: UUID) {
        guard !isDraggingOut, !incomingDrag, !externalDragActive,
              !closingEditorsForTermination else { return }
        if let editor = imageEditors[id] {
            panel.closePreview()
            collapse()
            editor.present()
            return
        }
        guard !loadingEditors.contains(id), let entry = entries.first(where: { $0.id == id }), canEdit(entry) else { return }
        loadingEditors.insert(id)
        let url = url(for: entry)
        io.async { [weak self] in
            let result = Result { try EditableImage(url: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingEditors.remove(id)
                guard self.entries.contains(entry), !self.closingEditorsForTermination else { return }
                do {
                    let editor = ImageEditor(entry: entry, source: try result.get())
                    editor.onSave = { [weak self] data, revision, completion in
                        guard let self else { completion(.failure(ImageEditError.renderFailed)); return }
                        self.saveEditedImage(data, id: id, expectedRevision: revision, completion: completion)
                    }
                    editor.onClose = { [weak self, weak editor] in
                        DispatchQueue.main.async {
                            guard let self, self.imageEditors[id] === editor else { return }
                            self.imageEditors.removeValue(forKey: id)
                            guard self.imageEditors.isEmpty, !self.closingEditorsForTermination else { return }
                            self.returnToShelf(afterEditing: id)
                        }
                    }
                    self.imageEditors[id] = editor
                    self.panel.closePreview()
                    self.collapse()
                    editor.present()
                } catch { self.report(error.localizedDescription) }
            }
        }
    }

    private func returnToShelf(afterEditing id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        switchSection(entry.category == .screenshots ? .screenshots : .files)
        selectOnly(id)
        showPinned()
        view.revealCard(id)
    }

    func saveEditedImage(_ data: Data, id: UUID, expectedRevision: UUID?,
                         completion: @escaping (Result<TrayEntry, Error>) -> Void) {
        busy += 1
        let settings = entries.first(where: { $0.id == id })?.category == .screenshots ? screenshotSettings : nil
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.storage.saveEditedImage(data, for: id, expectedRevision: expectedRevision,
                                                                   screenshotFolder: settings?.resolvedFolder()) }
            let snapshot = self.storage.items
            DispatchQueue.main.async {
                self.busy = max(0, self.busy - 1)
                if case .success = result {
                    self.applySnapshot(snapshot)
                }
                completion(result)
            }
        }
    }

    func closeEditorsForTermination(completion: @escaping (Bool) -> Void) {
        closingEditorsForTermination = true
        var remaining = Array(imageEditors.values)
        func closeNext() {
            guard let editor = remaining.popLast() else { completion(true); return }
            editor.requestClose { closed in
                if closed { closeNext() }
                else { self.closingEditorsForTermination = false; completion(false) }
            }
        }
        closeNext()
    }
    @objc func chooseFiles() {
        choosingFiles = true
        view.updateState()
        let picker = NSOpenPanel()
        picker.title = "Добавить на полку"
        picker.prompt = "Добавить"
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            self.choosingFiles = false
            self.view.updateState()
            if response == .OK { self.importURLs(picker.urls) }
            self.scheduleCollapse()
        }
    }
    func goToFolder() {
        guard !sendingShortcut, !choosingFiles, !isDraggingOut, !incomingDrag else { return }
        switch shortcutActions.prepareGoToFolder() {
        case .failure(.accessibilityPermissionRequired):
            showShortcutPermission()
        case .failure(let error):
            report(error.localizedDescription)
        case .success(let shortcut):
            sendingShortcut = true
            message = nil
            hasError = false
            collapse()
            // Hiding the nonactivating panel releases any key focus acquired
            // while selecting files, returning it to the target's open/save UI.
            panel.orderOut(nil)
            shortcutActions.send(shortcut) { [weak self] result in
                guard let self else { return }
                self.sendingShortcut = false
                self.panel.orderFrontRegardless()
                if case .failure(let error) = result {
                    self.report(error.localizedDescription)
                    self.showPinned()
                }
            }
        }
    }
    private func showShortcutPermission() {
        choosingFiles = true
        view.updateState()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "macOS не разрешает отправку ⌘⇧G"
        alert.informativeText = "Откройте «Системные настройки → Конфиденциальность и безопасность → Управление устройством и доступ к данным» (в прежних macOS — «Универсальный доступ»). Если Notch Tray уже включён, завершите приложение, удалите его из списка кнопкой «−» и добавьте заново из «Программ». Затем запустите Notch Tray и повторите действие в нужном окне. Файлы полки сохранятся."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        let response = alert.runModal()
        choosingFiles = false
        view.updateState()
        collapse()
        if response == .alertFirstButtonReturn {
            shortcutActions.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    func showShelfMenu(from button: NSView) {
        showingShelfMenu = true
        closeWork?.cancel()
        closeWork = nil
        defer { showingShelfMenu = false; scheduleCollapse() }
        let menu = NSMenu()
        add("Выбрать всё", to: menu, action: #selector(selectAll))
        add("Убрать выбранное", to: menu, action: #selector(removeSelected), enabled: !selection.isEmpty)
        add(activeSection == .screenshots ? "Очистить скриншоты" : "Очистить файлы", to: menu, action: #selector(clearShelf), enabled: !visibleEntries.isEmpty && !isDraggingOut)
        menu.addItem(.separator())
        menu.addItem(screenshotSettingsMenuItem())
        menu.addItem(.separator())
        add("Свернуть", to: menu, action: #selector(collapseFromMenu))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }
    func screenshotSettingsMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        add("Автоматически добавлять новые скриншоты", to: menu, action: #selector(toggleScreenshotImport))
        menu.items.last?.state = screenshotSettings.automaticImport ? .on : .off
        add("Убирать после успешного перетаскивания", to: menu, action: #selector(toggleScreenshotRemoval))
        menu.items.last?.state = screenshotSettings.removeAfterDrag ? .on : .off
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Папка: \(screenshotFolder.path)", action: nil, keyEquivalent: "")
        folder.isEnabled = false
        folder.toolTip = screenshotFolder.path
        menu.addItem(folder)
        if let issue = screenshotMonitorStatus?.issue {
            let item = NSMenuItem(title: issue, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = issue
            menu.addItem(item)
        }
        add("Выбрать папку…", to: menu, action: #selector(chooseScreenshotFolder), enabled: !choosingFiles)
        add("Использовать папку macOS", to: menu, action: #selector(useSystemScreenshotFolder))
        menu.items.last?.state = screenshotSettings.customFolderPath == nil ? .on : .off
        add("Показать папку в Finder", to: menu, action: #selector(showScreenshotFolder))
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Область: ⇧⌘4 · весь экран: ⇧⌘3", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let item = NSMenuItem(title: "Настройки скриншотов", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
    @objc private func toggleScreenshotImport() {
        var settings = screenshotSettings
        settings.automaticImport.toggle()
        do { try saveScreenshotSettings(settings) }
        catch { report("Не удалось сохранить настройки: \(error.localizedDescription)") }
    }
    @objc private func toggleScreenshotRemoval() {
        var settings = screenshotSettings
        settings.removeAfterDrag.toggle()
        do { try saveScreenshotSettings(settings) }
        catch { report("Не удалось сохранить настройки: \(error.localizedDescription)") }
    }
    @objc private func useSystemScreenshotFolder() {
        var settings = screenshotSettings
        settings.customFolderPath = nil
        do { try saveScreenshotSettings(settings) }
        catch { report("Не удалось сохранить настройки: \(error.localizedDescription)") }
    }
    @objc private func showScreenshotFolder() { NSWorkspace.shared.open(screenshotFolder) }
    @objc private func chooseScreenshotFolder() {
        guard !choosingFiles, !isDraggingOut else { return }
        choosingFiles = true
        view.updateState()
        let picker = NSOpenPanel()
        picker.title = "Папка скриншотов"
        picker.message = "Выберите ту же папку, что указана в ⇧⌘5 → Параметры. Tray будет добавлять только новые скриншоты."
        picker.prompt = "Выбрать"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = screenshotFolder
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            self.choosingFiles = false
            if response == .OK, let url = picker.url {
                var settings = self.screenshotSettings
                settings.customFolderPath = url.path
                settings.folderBookmark = nil
                do { try self.saveScreenshotSettings(settings) }
                catch { self.report("Не удалось сохранить папку: \(error.localizedDescription)") }
            }
            self.view.updateState()
            self.scheduleCollapse()
        }
    }
    @objc private func collapseFromMenu() {
        showingShelfMenu = false
        collapse()
    }
    func showPinned() {
        guard imageEditors.isEmpty, !closingEditorsForTermination else { return }
        isPinned = true
        expand()
        if isExpanded, canSwitchSections, !panel.isPreviewing { panel.focusShelf() }
    }
    @objc func toggle() { if isExpanded { collapse() } else { showPinned() } }
    @objc func quit() {
        if busy > 0 {
            let alert = NSAlert()
            alert.messageText = "Файлы ещё добавляются"
            alert.informativeText = "Дождись завершения копирования и закрой приложение ещё раз."
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }
    @objc func showStorage() { NSWorkspace.shared.open(storage.root) }
    @objc func showReadme() { openResource("README", ext: "md") }
    @objc func showLicense() { openResource("THIRD_PARTY_NOTICES", ext: "md") }
    private func openResource(_ name: String, ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { NSWorkspace.shared.open(url) }
    }
    private func add(_ title: String, to menu: NSMenu, action: Selector, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        menu.autoenablesItems = false
    }
    private func makeMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Notch Tray")
            statusItem.button?.toolTip = "Notch Tray — полка для файлов"
        }
        let menu = NSMenu()
        add("Открыть / свернуть полку", to: menu, action: #selector(toggle))
        add("Добавить файлы…", to: menu, action: #selector(chooseFiles))
        menu.addItem(screenshotSettingsMenuItem())
        let screens = NSMenu()
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(selectScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screenID(screen)
            item.state = screenID(screen) == screenID(geometry.screen) ? .on : .off
            screens.addItem(item)
        }
        let screenItem = NSMenuItem(title: "Экран", action: nil, keyEquivalent: "")
        screenItem.submenu = screens
        menu.addItem(screenItem)
        menu.addItem(.separator())
        add("Показать хранилище", to: menu, action: #selector(showStorage))
        add("Как пользоваться", to: menu, action: #selector(showReadme))
        if let updates = releaseUpdates {
            let title = updates.availableVersion.map { "Скачать версию " + $0 + "…" } ?? "Проверить обновления…"
            let check = menu.addItem(withTitle: title, action: #selector(ReleaseUpdates.manualCheck), keyEquivalent: "")
            check.target = updates
            let automatic = menu.addItem(withTitle: "Проверять обновления автоматически",
                                         action: #selector(ReleaseUpdates.toggleAutomatic), keyEquivalent: "")
            automatic.target = updates
            automatic.state = updates.automatic ? .on : .off
        }
        add("О приложении и лицензиях", to: menu, action: #selector(showLicense))
        menu.addItem(.separator())
        add("Завершить Notch Tray", to: menu, action: #selector(quit))
        statusItem.menu = menu
    }

    func startReleaseChecks() {
        let updates = ReleaseUpdates()
        releaseUpdates = updates
        updates.onChange = { [weak self] in
            self?.makeMenu()
            self?.view.updateState()
        }
        makeMenu()
        updates.start()
    }
    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    @objc private func selectScreen(_ item: NSMenuItem) { userScreenID = item.representedObject as? UInt32; updateScreen() }
    private func updateScreen() {
        guard let screen = NSScreen.screens.first(where: { screenID($0) == userScreenID }) ??
                NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        geometry = NotchGeometry(screen: screen)
        panel.updatePreviewLayout(in: geometry.previewFrame)
        resize(animated: false)
        view.updateState()
        panel.orderFrontRegardless()
        makeMenu()
    }
    deinit {
        cleanupTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenshotMonitor?.stop()
        displayLink?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
