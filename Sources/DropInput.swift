// Notch Tray — GPL-3.0. Native AppKit file URLs and file promises.
import AppKit

enum DropInput {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff] +
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static func accepts(_ board: NSPasteboard) -> Bool {
        !(Set(board.types ?? []).intersection(types)).isEmpty
    }
    static func fileURLs(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

class DropSurface: NSView {
    weak var controller: TrayController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropInput.types)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard controller != nil, controller?.isDraggingOut != true,
              sender.draggingSourceOperationMask.contains(.copy),
              DropInput.accepts(sender.draggingPasteboard) else { return [] }
        return .copy
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard operation(sender) == .copy else { return [] }
        controller?.armExternalDrag()
        controller?.incomingDrag = true
        controller?.expand()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = operation(sender)
        controller?.incomingDrag = result == .copy
        return result
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.endIncomingDrag() }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.finishExternalDrag() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { operation(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard operation(sender) == .copy else { return false }
        return controller?.accept(sender.draggingPasteboard) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { controller?.finishExternalDrag() }
}
