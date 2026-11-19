// Adapted from BoringNotchWindow.swift (TheBoredTeam, GPL-3.0) and
// Ext+NSScreen.swift (Copyright 2024 Lakr Aream, MIT). Modified 2026-10-26.
import AppKit
import Quartz

extension NSEvent {
    private var hasShortcutModifiers: Bool {
        !modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }
    var isUnmodifiedSpace: Bool {
        charactersIgnoringModifiers == " " && !hasShortcutModifiers
    }
    var previewStep: Int? {
        guard type == .keyDown, !hasShortcutModifiers else { return nil }
        switch keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }
}

struct NotchGeometry {
    let screen: NSScreen
    var notchHeight: CGFloat { screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 25 }
    var notchWidth: CGFloat {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return screen.frame.width - left.width - right.width
        }
        return 160
    }
    // An invisible hover target confined to the hardware notch. No shoulders.
    var closedSize: NSSize { NSSize(width: notchWidth, height: notchHeight) }
    var openSize: NSSize { NSSize(width: min(560, screen.frame.width - 40), height: notchHeight + 164) }
    func frame(open: Bool) -> NSRect {
        let size = open ? openSize : closedSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }
    var trigger: NSRect { frame(open: false) }
    var previewFrame: NSRect {
        PreviewWindowLayout.availableFrame(visibleFrame: screen.visibleFrame, shelfFrame: frame(open: true))
    }
}

final class NotchPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURL: URL?
    private var previewLayout: PreviewWindowLayout?
    private(set) var imagePreview: ImagePreviewWindow?
    private var previewKeyMonitor: Any?
    private var shelf: ShelfView? { contentView as? ShelfView }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = false
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        if #available(macOS 13.0, *) { collectionBehavior.insert(.canJoinAllApplications) }
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
        ignoresMouseEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: name, object: nil)
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { (contentView as? ShelfView)?.controller?.collapse() }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        shelf?.updateSelectionFocus()
        return changed
    }

    @objc private func keyWindowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self || window === previewWindow else { return }
        shelf?.updateSelectionFocus()
    }

    func focusShelf() {
        guard let shelf, makeFirstResponder(shelf) else { return }
        makeKey()
    }

    var isPreviewing: Bool { previewWindow?.isVisible == true }
    var previewWindow: NSWindow? { imagePreview ?? (previewURL == nil ? nil : QLPreviewPanel.shared()) }

    func showPreview(of url: URL, in availableFrame: NSRect, edit: (() -> Void)? = nil) {
        if let edit, let imagePreview {
            imagePreview.onEdit = edit
            if imagePreview.fileURL != url { imagePreview.update(url: url) }
            return
        }
        if edit == nil, previewURL != nil {
            if previewURL != url {
                previewURL = url
                QLPreviewPanel.shared()?.reloadData()
            }
            return
        }
        let previous = previewWindow
        let shouldFocus = previous?.isKeyWindow ?? true
        closePreviewWindow()
        if let edit {
            let window = ImagePreviewWindow(url: url)
            imagePreview = window
            window.onEdit = edit
            window.onClose = { [weak self, weak window] in
                guard let self, let window, self.imagePreview === window else { return }
                self.imagePreview = nil
                self.closePreview()
            }
            previewLayout = PreviewWindowLayout(window: window, availableFrame: availableFrame)
            presentPreview(window, focus: shouldFocus)
            return
        }
        guard let preview = QLPreviewPanel.shared() else { closePreview(); return }
        previewLayout = PreviewWindowLayout(window: preview, availableFrame: availableFrame)
        previewURL = url
        if shouldFocus, previous != nil { focusShelf() }
        preview.updateController()
        if preview.currentController as? NotchPanel === self { preview.reloadData() }
        presentPreview(preview, focus: shouldFocus)
    }

    private func presentPreview(_ window: NSWindow, focus: Bool) {
        if previewKeyMonitor == nil {
            // Quick Look can consume arrow keys before invoking its delegate.
            previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let step = event.previewStep, let window = self.previewWindow,
                      window.isKeyWindow, event.window === window else { return event }
                self.shelf?.controller?.updatePreview(step: step)
                return nil
            }
        }
        if focus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
        }
        shelf?.updateSelectionFocus()
    }

    func closePreview() {
        let ended = shelf?.controller?.endPreview() == true
        closePreviewWindow()
        if let previewKeyMonitor {
            NSEvent.removeMonitor(previewKeyMonitor)
            self.previewKeyMonitor = nil
        }
        if ended { restoreShelfFocus() }
        shelf?.updateSelectionFocus()
    }

    private func closePreviewWindow() {
        let window = previewWindow
        imagePreview = nil
        previewURL = nil
        previewLayout = nil
        window?.close()
    }

    func updatePreviewLayout(in availableFrame: NSRect) { previewLayout?.update(availableFrame: availableFrame) }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        // The shelf can receive the initial Space while another app is active.
        if let imagePreview, imagePreview.isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === self {
            imagePreview.makeKey()
            return
        }
        guard previewURL != nil, let preview = QLPreviewPanel.shared(), preview.isVisible,
              NSApp.keyWindow == nil || NSApp.keyWindow === self else { return }
        preview.makeKey()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        restoreFocusAfterPreview(panel)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.isUnmodifiedSpace || event.keyCode == 53 else { return false }
        if !event.isARepeat { panel.close() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel else { return }
        restoreFocusAfterPreview(panel)
    }

    private func restoreFocusAfterPreview(_ panel: QLPreviewPanel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !panel.isVisible, self.previewURL != nil else { return }
            self.previewURL = nil
            self.closePreview()
        }
    }

    private func restoreShelfFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPreviewing, NSApp.isActive, let shelf = self.contentView as? ShelfView,
                  shelf.controller?.isExpanded == true, NSApp.keyWindow == nil || NSApp.keyWindow === self else { return }
            self.focusShelf()
        }
    }

    deinit {
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
    }
}

// Mouse-only monitoring: no keyboard capture, Accessibility or polling timer.
// Adapted from boring.notch DragDetector.swift (Alexander, 2025-11-20).
final class DragObserver {
    var onMove: ((NSPoint, Bool) -> Void)?
    var onRelease: (() -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onHover: ((NSPoint) -> Void)?
    private var global: Any?
    private var local: Any?
    private var initialChange = -1
    private var contentDrag = false

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.handle($0) }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }
    private func handle(_ event: NSEvent) {
        let pasteboard = NSPasteboard(name: .drag)
        switch event.type {
        case .mouseMoved:
            onHover?(NSEvent.mouseLocation)
        case .leftMouseDown:
            onMouseDown?(NSEvent.mouseLocation)
            initialChange = pasteboard.changeCount
            contentDrag = false
        case .leftMouseDragged:
            if pasteboard.changeCount != initialChange && DropInput.accepts(pasteboard) { contentDrag = true }
            onMove?(NSEvent.mouseLocation, contentDrag)
        case .leftMouseUp:
            contentDrag = false
            onRelease?()
        default: break
        }
    }
    deinit {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
    }
}
