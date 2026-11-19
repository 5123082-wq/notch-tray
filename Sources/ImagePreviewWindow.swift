// Quick Look's embeddable view leaves room for a supported Edit action. GPL-3.0.
import AppKit
import Quartz

final class ImagePreviewWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    let previewView: QLPreviewView
    let editButton = NSButton(title: "Редактировать", target: nil, action: nil)
    private(set) var fileURL: URL
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?

    init(url: URL) {
        fileURL = url
        previewView = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 860, height: 640), style: .normal)
        super.init(contentRect: previewView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 560, height: 360)
        title = url.lastPathComponent
        delegate = self
        contentView = previewView
        previewView.autoresizingMask = [.width, .height]
        previewView.previewItem = url as NSURL
        let toolbar = NSToolbar(identifier: "ImagePreviewToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        toolbarStyle = .unified
        editButton.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)
        editButton.imagePosition = .imageLeading
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editImage)
        editButton.toolTip = "Редактировать изображение (⌘E)"
    }
    override var canBecomeKey: Bool { true }
    func update(url: URL) {
        fileURL = url
        title = url.lastPathComponent
        previewView.previewItem = url as NSURL
        previewView.refreshPreviewItem()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("edit"), .init("share"), .init("open")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "edit": item.label = "Редактировать"; item.view = editButton
        case "open":
            let button = NSButton(title: "Открыть в приложении", target: self, action: #selector(openFile))
            button.bezelStyle = .rounded
            item.label = button.title; item.view = button
        case "share":
            item.label = "Поделиться"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Поделиться")
            item.target = self; item.action = #selector(shareFile(_:))
        default: return nil
        }
        return item
    }
    @objc func editImage() { onEdit?() }
    @objc private func openFile() { NSWorkspace.shared.open(fileURL) }
    @objc private func shareFile(_ sender: NSToolbarItem) {
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: NSRect(x: previewView.bounds.maxX - 80, y: previewView.bounds.maxY - 2, width: 1, height: 1),
                    of: previewView, preferredEdge: .minY)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.isUnmodifiedSpace || event.keyCode == 53 {
                if !event.isARepeat { close() }
                return
            }
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               event.charactersIgnoringModifiers == "e" { editImage(); return }
        }
        super.sendEvent(event)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
