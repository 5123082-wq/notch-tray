// Screenshot markup with full-resolution image export. GPL-3.0.
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageEditError: LocalizedError {
    case unsupported, tooLarge, renderFailed
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Для разметки выберите обычное изображение PNG, JPEG, HEIC или TIFF."
        case .tooLarge: return "Это изображение слишком большое для редактора (более 80 мегапикселей)."
        case .renderFailed: return "Не удалось сохранить изображение. Правки остались в редакторе."
        }
    }
}

struct EditableImage {
    let image: CGImage
    var bounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    static func supports(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) else { return false }
        return [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier].contains(type as String)
    }

    init(url: URL) throws {
        guard Self.supports(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageEditError.unsupported }
        guard width <= 80_000_000 / height else { throw ImageEditError.tooLarge }
        // ImageIO applies EXIF orientation at the original pixel resolution.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageEditError.unsupported
        }
        self.image = image
    }

    func png(annotations: [ImageAnnotation]) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageEditError.renderFailed }
        context.draw(image, in: bounds)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        for annotation in annotations { annotation.draw(in: context) }
        guard let rendered = context.makeImage() else { throw ImageEditError.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageEditError.renderFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageEditError.renderFailed }
        return data as Data
    }
}

private final class ImageEditorScrollView: NSScrollView {
    private let imageView: NSImageView
    private let canvas: AnnotationCanvas
    private let imageSize: CGSize
    var zoom: CGFloat? { didSet { needsLayout = true } }

    init(source: EditableImage, canvas: AnnotationCanvas) {
        self.canvas = canvas
        imageSize = source.bounds.size
        imageView = NSImageView(frame: .zero)
        imageView.image = NSImage(cgImage: source.image, size: imageSize)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.unregisterDraggedTypes()
        super.init(frame: .zero)
        backgroundColor = .underPageBackgroundColor
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        let surface = NSView()
        surface.addSubview(imageView)
        surface.addSubview(canvas)
        documentView = surface
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layout() {
        super.layout()
        guard let surface = documentView, contentSize.width > 0, contentSize.height > 0 else { return }
        let visible = contentView.bounds
        let padding: CGFloat = 24
        let fitScale = min(max(1, visible.width - 2 * padding) / imageSize.width,
                           max(1, visible.height - 2 * padding) / imageSize.height)
        let scale = zoom ?? min(1, fitScale)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let documentSize = CGSize(width: max(visible.width, size.width + 2 * padding),
                                  height: max(visible.height, size.height + 2 * padding))
        let imageFrame = CGRect(x: (documentSize.width - size.width) / 2,
                                y: (documentSize.height - size.height) / 2,
                                width: size.width, height: size.height)
        let previous = imageView.frame
        guard surface.frame.size != documentSize || previous != imageFrame else { return }
        let x = previous.width > 0 ? (visible.midX - previous.minX) / previous.width : 0.5
        let y = previous.height > 0 ? (visible.midY - previous.minY) / previous.height : 0.5
        surface.setFrameSize(documentSize)
        imageView.frame = imageFrame
        canvas.frame = imageFrame
        let center = CGPoint(x: imageFrame.minX + imageFrame.width * x,
                             y: imageFrame.minY + imageFrame.height * y)
        let proposed = CGRect(x: center.x - visible.width / 2, y: center.y - visible.height / 2,
                              width: visible.width, height: visible.height)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
}

final class ImageEditor: NSWindowController, NSWindowDelegate {
    private(set) var revision: UUID?
    let source: EditableImage
    let canvas: AnnotationCanvas
    private let scrollView: ImageEditorScrollView
    let saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
    private var toolButtons: [AnnotationToolbarButton] = []
    private let shapesPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private var selectedShape: AnnotationTool = .frame
    private var colorButtons: [AnnotationToolbarButton] = []
    private var widthButtons: [AnnotationToolbarButton] = []
    private let zoomPicker = NSPopUpButton()
    private let undoButton = AnnotationToolbarButton(title: "", help: "Отменить (⌘Z)",
                                                       symbol: "arrow.uturn.backward", width: 25)
    private let redoButton = AnnotationToolbarButton(title: "", help: "Повторить (⇧⌘Z)",
                                                       symbol: "arrow.uturn.forward", width: 25)
    private let history = UndoManager()
    private var savedAnnotations: [ImageAnnotation] = []
    private var hasShelfOnlyScreenshotEdits: Bool
    private(set) var isSaving = false
    private var isConfirmingClose = false
    private var allowsClose = false
    private var needsActivationFocus = false
    private var activationObserver: NSObjectProtocol?
    var onSave: ((Data, UUID?, @escaping (Result<TrayEntry, Error>) -> Void) -> Void)?
    var onClose: (() -> Void)?
    var hasChanges: Bool { canvas.annotationsIncludingText != savedAnnotations }

    private let colors: [(String, CGColor)] = [
        ("Красный", CGColor(srgbRed: 0.95, green: 0.16, blue: 0.22, alpha: 1)),
        ("Синий", CGColor(srgbRed: 0.1, green: 0.43, blue: 1, alpha: 1)),
        ("Зелёный", CGColor(srgbRed: 0.13, green: 0.65, blue: 0.31, alpha: 1)),
        ("Жёлтый", CGColor(srgbRed: 1, green: 0.77, blue: 0.12, alpha: 1)),
        ("Белый", CGColor(gray: 1, alpha: 1)),
        ("Чёрный", CGColor(gray: 0.05, alpha: 1))
    ]
    private let widths: [CGFloat] = [2, 4, 7]
    private var widthScale: CGFloat { max(1, min(source.bounds.width, source.bounds.height) / 500) }

    init(entry: TrayEntry, source: EditableImage) {
        revision = entry.imageRevision
        hasShelfOnlyScreenshotEdits = entry.category == .screenshots && entry.imageRevision != nil && entry.screenshotSourcePath == nil
        self.source = source
        canvas = AnnotationCanvas(imageSize: source.bounds.size)
        scrollView = ImageEditorScrollView(source: source, canvas: canvas)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
        let width = min(1000, max(800, (screen?.width ?? 1048) - 48))
        let height = min(720, max(420, (screen?.height ?? 768) - 48))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Разметка — \(entry.name)"
        window.contentMinSize = NSSize(width: 800, height: 420)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.center()
        history.groupsByEvent = false

        configureControls()
        var tools: [NSView] = toolButtons
        tools.insert(shapesPicker, at: 1)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [
            AnnotationToolbarGroup(controls: tools),
            AnnotationToolbarGroup(controls: colorButtons, spacing: 1),
            AnnotationToolbarGroup(controls: widthButtons, spacing: 1),
            AnnotationToolbarGroup(controls: [undoButton, redoButton]),
            spacer, zoomPicker, saveButton
        ])
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        toolbar.spacing = 6
        let header = AnnotationToolbarBackground()
        header.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for view in [header, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            toolbar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        canvas.onChange = { [weak self] in self?.replaceAnnotations(with: $0) }
        canvas.onStyleChange = { [weak self] in self?.syncStyleButtons() }
        canvas.onTextChange = { [weak self] in self?.updateState() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                guard let self, self.needsActivationFocus, self.window?.isVisible == true else { return }
                self.needsActivationFocus = false
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.canvas.preferredResponder)
            }
        updateState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func present() {
        needsActivationFocus = !NSApp.isActive
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(canvas.preferredResponder)
        NSApp.activate()
    }

    private func configureControls() {
        toolButtons = [AnnotationTool.arrow, .pen, .text].map { tool in
            let button = AnnotationToolbarButton(title: tool.title, help: tool.title,
                                                  symbol: tool.symbol, width: tool == .arrow ? 74 : 58, isChoice: true)
            button.tag = tool.rawValue
            button.target = self
            button.action = #selector(chooseTool(_:))
            return button
        }
        shapesPicker.addItem(withTitle: "Фигуры")
        for tool in AnnotationTool.shapes {
            let item = NSMenuItem(title: tool.title, action: #selector(chooseShape(_:)), keyEquivalent: "")
            item.tag = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            item.target = self
            shapesPicker.menu?.addItem(item)
        }
        shapesPicker.controlSize = .small
        shapesPicker.font = .systemFont(ofSize: 12, weight: .medium)
        shapesPicker.setAccessibilityLabel("Фигуры")
        shapesPicker.widthAnchor.constraint(equalToConstant: 82).isActive = true
        colorButtons = colors.enumerated().map { index, color in
            let button = AnnotationToolbarButton(title: "", help: color.0, mark: .swatch(color.1),
                                                  width: 20, isChoice: true)
            button.tag = index
            button.target = self
            button.action = #selector(chooseColor(_:))
            return button
        }
        widthButtons = ["Тонкая линия", "Средняя линия", "Толстая линия"].enumerated().map { index, title in
            let button = AnnotationToolbarButton(title: "", help: title, mark: .stroke(CGFloat(index) + 1.5),
                                                  width: 18, isChoice: true)
            button.tag = index
            button.target = self
            button.action = #selector(chooseWidth(_:))
            return button
        }
        zoomPicker.addItems(withTitles: ["Вписать", "50 %", "100 %", "200 %"])
        zoomPicker.controlSize = .small
        zoomPicker.font = .systemFont(ofSize: 12, weight: .medium)
        zoomPicker.toolTip = "Масштаб изображения"
        zoomPicker.setAccessibilityLabel("Масштаб")
        zoomPicker.target = self
        zoomPicker.action = #selector(chooseZoom)
        zoomPicker.widthAnchor.constraint(equalToConstant: 98).isActive = true
        undoButton.target = self
        undoButton.action = #selector(undo(_:))
        redoButton.target = self
        redoButton.action = #selector(redo(_:))
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        saveButton.imagePosition = .imageLeading
        saveButton.target = self
        saveButton.action = #selector(saveDocument(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.widthAnchor.constraint(equalToConstant: 99).isActive = true
        canvas.setStyle(color: colors[0].1, width: widths[1] * widthScale)
        syncStyleButtons()
    }

    @objc private func chooseTool(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        canvas.tool = tool
        syncStyleButtons()
        window?.makeFirstResponder(canvas)
    }

    @objc private func chooseShape(_ item: NSMenuItem) {
        guard let tool = AnnotationTool(rawValue: item.tag), AnnotationTool.shapes.contains(tool) else { return }
        selectedShape = tool
        canvas.tool = tool
        syncStyleButtons()
        window?.makeFirstResponder(canvas)
    }

    @objc private func chooseColor(_ sender: NSButton) {
        canvas.setStyle(color: colors[sender.tag].1)
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    @objc private func chooseWidth(_ sender: NSButton) {
        canvas.setStyle(width: widths[sender.tag] * widthScale)
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    private func syncStyleButtons() {
        for button in toolButtons { button.selected = button.tag == canvas.tool.rawValue }
        let shapeActive = AnnotationTool.shapes.contains(canvas.tool)
        if shapeActive { selectedShape = canvas.tool }
        shapesPicker.contentTintColor = shapeActive ? .controlAccentColor : nil
        shapesPicker.toolTip = "Фигуры — " + selectedShape.title
        for item in shapesPicker.itemArray.dropFirst() {
            item.state = item.tag == selectedShape.rawValue ? .on : .off
        }
        for button in colorButtons { button.selected = colors[button.tag].1 == canvas.styleColor }
        for button in widthButtons { button.selected = widths[button.tag] * widthScale == canvas.styleWidth }
    }

    @objc private func chooseZoom() {
        let zooms: [CGFloat?] = [nil, 0.5, 1, 2]
        guard zooms.indices.contains(zoomPicker.indexOfSelectedItem) else { return }
        canvas.resetSelection()
        scrollView.zoom = zooms[zoomPicker.indexOfSelectedItem]
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    private func replaceAnnotations(with annotations: [ImageAnnotation]) {
        let previous = canvas.annotations
        guard previous != annotations else { return }
        let separateStep = !history.isUndoing && !history.isRedoing
        if separateStep { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { $0.replaceAnnotations(with: previous) }
        history.setActionName("Разметка")
        if separateStep { history.endUndoGrouping() }
        canvas.annotations = annotations
        updateState()
    }

    private func updateState() {
        saveButton.isEnabled = (hasChanges || hasShelfOnlyScreenshotEdits) && !isSaving
        saveButton.title = isSaving ? "Сохраняю…" : "Сохранить"
        let pendingText = canvas.annotationsIncludingText != canvas.annotations
        undoButton.isEnabled = (history.canUndo || pendingText) && !isSaving
        redoButton.isEnabled = history.canRedo && !pendingText && !isSaving
        for button in toolButtons + colorButtons + widthButtons { button.isEnabled = !isSaving }
        shapesPicker.isEnabled = !isSaving
        zoomPicker.isEnabled = !isSaving
        window?.isDocumentEdited = hasChanges
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }

    @objc func undo(_ sender: Any?) {
        guard !isSaving else { return }
        canvas.finishText()
        canvas.resetSelection()
        history.undo()
        updateState()
    }

    @objc func redo(_ sender: Any?) {
        guard !isSaving else { return }
        canvas.finishText()
        canvas.resetSelection()
        history.redo()
        updateState()
    }

    @objc func saveDocument(_ sender: Any?) {
        save { [weak self] saved in
            if saved { self?.closeAfterConfirmation() }
        }
    }

    func save(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else { completion?(false); return }
        canvas.finishText()
        guard hasChanges || hasShelfOnlyScreenshotEdits else { completion?(true); return }
        canvas.resetSelection()
        let snapshot = canvas.annotations
        isSaving = true
        canvas.isEditable = false
        updateState()
        Task { @MainActor [self] in
            do {
                let image = source
                let data = try await Task.detached(priority: .userInitiated) {
                    try image.png(annotations: snapshot)
                }.value
                guard let onSave else { throw ImageEditError.renderFailed }
                onSave(data, revision) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let entry):
                        self.revision = entry.imageRevision
                        self.hasShelfOnlyScreenshotEdits = false
                        self.savedAnnotations = snapshot
                        self.window?.title = "Разметка — \(entry.name)"
                        self.finishSave()
                        completion?(true)
                    case .failure(let error): self.finishSave(error: error); completion?(false)
                    }
                }
            } catch { finishSave(error: error); completion?(false) }
        }
    }
    private func finishSave(error: Error? = nil) {
        isSaving = false
        canvas.isEditable = true
        updateState()
        if let error, let window {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsClose { return true }
        requestClose { _ in }
        return false
    }
    func requestClose(completion: @escaping (Bool) -> Void) {
        guard !isSaving, !isConfirmingClose, let window, window.attachedSheet == nil else { completion(false); return }
        canvas.finishText()
        guard hasChanges else { closeAfterConfirmation(); completion(true); return }
        isConfirmingClose = true
        let alert = NSAlert()
        alert.messageText = "Сохранить изменения?"
        alert.informativeText = "Несохранённые пометки будут потеряны."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Не сохранять")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            self.isConfirmingClose = false
            if response == .alertFirstButtonReturn {
                self.save { saved in
                    if saved { self.closeAfterConfirmation() }
                    completion(saved)
                }
            } else if response == .alertThirdButtonReturn {
                self.closeAfterConfirmation(); completion(true)
            } else { completion(false) }
        }
    }
    private func closeAfterConfirmation() { allowsClose = true; window?.close() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
}
