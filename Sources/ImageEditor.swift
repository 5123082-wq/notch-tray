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
    private static let maximumPixels = 80_000_000
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
        guard width <= Self.maximumPixels / height else { throw ImageEditError.tooLarge }
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
        let artboard = AnnotationArtboard.bounds(for: bounds, annotations: annotations)
        guard artboard.height <= CGFloat(Self.maximumPixels),
              artboard.width <= CGFloat(Self.maximumPixels / Int(artboard.height)) else { throw ImageEditError.tooLarge }
        guard let context = CGContext(data: nil, width: Int(artboard.width), height: Int(artboard.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageEditError.renderFailed }
        context.draw(image, in: CGRect(x: -artboard.minX, y: artboard.maxY - bounds.height,
                                       width: bounds.width, height: bounds.height))
        context.translateBy(x: -artboard.minX, y: artboard.maxY)
        context.scaleBy(x: 1, y: -1)
        AnnotationArtboard.drawPadding(in: context, source: bounds, artboard: artboard)
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
        let surface = FlippedView()
        surface.addSubview(imageView)
        surface.addSubview(canvas)
        documentView = surface
        canvas.onGeometryChange = { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        canvas.onDragScroll = { [weak self] in self?.scrollWhileDragging(at: $0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layout() {
        super.layout()
        guard let surface = documentView, contentSize.width > 0, contentSize.height > 0 else { return }
        let visible = contentView.bounds
        let padding: CGFloat = 24
        let previous = imageView.frame
        let artboard = canvas.contentBounds
        let anchoredDrag = canvas.isDragging && previous.width > 0
        let fitScale = min(max(1, visible.width - 2 * padding) / artboard.width,
                           max(1, visible.height - 2 * padding) / artboard.height)
        let scale = anchoredDrag ? canvas.scale : zoom ?? min(1, fitScale)
        let size = CGSize(width: artboard.width * scale, height: artboard.height * scale)

        let documentSize: CGSize
        let canvasFrame: CGRect
        let scrollOrigin: CGPoint
        if anchoredDrag {
            // Grow in document coordinates and shift the clip view by the same
            // offset, keeping existing image pixels stationary under the pointer.
            let frame = CGRect(x: previous.minX + artboard.minX * scale, y: previous.minY + artboard.minY * scale,
                               width: size.width, height: size.height)
            let document = frame.insetBy(dx: -padding, dy: -padding).union(visible)
            documentSize = document.size
            canvasFrame = frame.offsetBy(dx: -document.minX, dy: -document.minY)
            scrollOrigin = CGPoint(x: visible.minX - document.minX, y: visible.minY - document.minY)
        } else {
            documentSize = CGSize(width: max(visible.width, size.width + 2 * padding),
                                  height: max(visible.height, size.height + 2 * padding))
            canvasFrame = CGRect(x: (documentSize.width - size.width) / 2, y: (documentSize.height - size.height) / 2,
                                 width: size.width, height: size.height)
            let oldScale = canvas.scale
            let x = previous.width > 0 ? (visible.midX - previous.minX) / oldScale : artboard.midX
            let y = previous.height > 0 ? (visible.midY - previous.minY) / oldScale : artboard.midY
            scrollOrigin = CGPoint(x: canvasFrame.minX + (x - artboard.minX) * scale - visible.width / 2,
                                   y: canvasFrame.minY + (y - artboard.minY) * scale - visible.height / 2)
        }
        let imageFrame = CGRect(x: canvasFrame.minX - artboard.minX * scale,
                                y: canvasFrame.minY - artboard.minY * scale,
                                width: imageSize.width * scale, height: imageSize.height * scale)
        guard surface.frame.size != documentSize || previous != imageFrame || canvas.frame != canvasFrame else { return }
        surface.setFrameSize(documentSize)
        imageView.frame = imageFrame
        canvas.place(frame: canvasFrame, artboard: artboard, scale: scale)
        scroll(to: scrollOrigin)
    }

    private func scrollWhileDragging(at point: NSPoint) {
        let visible = contentView.bounds
        let location = contentView.convert(point, from: nil)
        let edge: CGFloat = 24
        func step(_ coordinate: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            if coordinate < lower + edge { return max(-edge, coordinate - lower - edge) * 0.5 }
            if coordinate > upper - edge { return min(edge, coordinate - upper + edge) * 0.5 }
            return 0
        }
        scroll(to: CGPoint(x: visible.minX + step(location.x, lower: visible.minX, upper: visible.maxX),
                           y: visible.minY + step(location.y, lower: visible.minY, upper: visible.maxY)))
    }

    private func scroll(to origin: CGPoint) {
        let proposed = CGRect(origin: origin, size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
}

final class ImageEditor: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    private(set) var revision: UUID?
    let source: EditableImage
    let canvas: AnnotationCanvas
    private let scrollView: ImageEditorScrollView
    let saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
    private var groupButtons: [AnnotationToolbarButton] = []
    private var variantGroups: [AnnotationTool.Group: AnnotationToolbarGroup] = [:]
    private var variantButtons: [AnnotationToolbarButton] = []
    private var recentTools: [AnnotationTool.Group: AnnotationTool] = [:]
    private var colorButtons: [AnnotationToolbarButton] = []
    private var widthButtons: [AnnotationToolbarButton] = []
    private var widthGroup: AnnotationToolbarGroup?
    private let fontSizePicker = NSComboBox()
    private var fontSizeGroup: AnnotationToolbarGroup?
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [
            AnnotationToolbarGroup(controls: groupButtons),
            AnnotationToolbarGroup(controls: colorButtons, spacing: 1),
            AnnotationToolbarGroup(controls: [undoButton, redoButton]),
            spacer, zoomPicker, saveButton
        ])
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        toolbar.spacing = 6
        let widths = AnnotationToolbarGroup(controls: widthButtons, spacing: 1)
        widthGroup = widths
        let fontSizeLabel = NSTextField(labelWithString: "Размер шрифта")
        fontSizeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let fontSize = AnnotationToolbarGroup(controls: [fontSizeLabel, fontSizePicker], spacing: 8)
        fontSize.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        fontSizeGroup = fontSize
        let options = NSStackView(views: AnnotationTool.Group.allCases.compactMap { variantGroups[$0] } + [widths, fontSize])
        options.alignment = .centerY
        options.spacing = 6
        options.detachesHiddenViews = true
        let header = AnnotationToolbarBackground()
        for row in [toolbar, options] {
            row.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(row)
        }
        let root = NSView()
        for view in [header, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 96),
            toolbar.topAnchor.constraint(equalTo: header.topAnchor, constant: 5),
            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            options.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            options.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            options.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor),
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
        syncStyleButtons()
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
        let groupIcons = ["arrow.up.right", "square.on.circle", "pencil.tip", "textformat"]
        let groupWidths: [CGFloat] = [78, 74, 114, 58]
        groupButtons = AnnotationTool.Group.allCases.map { group in
            let button = AnnotationToolbarButton(title: group.title, help: group.title,
                symbol: groupIcons[group.rawValue], width: groupWidths[group.rawValue], isChoice: true)
            button.tag = group.rawValue
            button.target = self
            button.action = #selector(chooseGroup(_:))
            return button
        }
        for group in AnnotationTool.Group.allCases where group != .text {
            let buttons = group.tools.map { tool in
                let button = AnnotationToolbarButton(title: tool.title, help: tool.title, symbol: tool.symbol,
                    width: tool == .doubleArrow || tool == .highlighter ? 115 : 93, isChoice: true)
                button.tag = tool.rawValue
                button.target = self
                button.action = #selector(chooseVariant(_:))
                return button
            }
            variantButtons += buttons
            variantGroups[group] = AnnotationToolbarGroup(controls: buttons)
        }
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
        fontSizePicker.addItems(withObjectValues: AnnotationFontSize.presets.map(String.init))
        fontSizePicker.numberOfVisibleItems = 8
        fontSizePicker.isEditable = true
        fontSizePicker.completes = false
        fontSizePicker.controlSize = .small
        fontSizePicker.font = .systemFont(ofSize: 12, weight: .medium)
        fontSizePicker.toolTip = "Размер шрифта от 6 до 512 пикселей"
        fontSizePicker.setAccessibilityLabel("Размер шрифта")
        fontSizePicker.translatesAutoresizingMaskIntoConstraints = false
        fontSizePicker.widthAnchor.constraint(equalToConstant: 78).isActive = true
        fontSizePicker.delegate = self
        fontSizePicker.target = self
        fontSizePicker.action = #selector(chooseFontSize(_:))
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
        canvas.setStyle(color: colors[0].1)
    }

    @objc private func chooseGroup(_ sender: NSButton) {
        guard let group = AnnotationTool.Group(rawValue: sender.tag) else { return }
        activateTool(recentTools[group] ?? group.tools[0])
    }

    @objc private func chooseVariant(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        activateTool(tool)
    }

    private func activateTool(_ tool: AnnotationTool) {
        finishFontSizeEntry()
        recentTools[tool.group] = tool
        canvas.tool = tool
        window?.makeFirstResponder(canvas)
    }

    @objc private func chooseColor(_ sender: NSButton) {
        canvas.setStyle(color: colors[sender.tag].1)
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    @objc private func chooseWidth(_ sender: NSButton) {
        let widths = canvas.styleTool.widthOptions
        guard widths.indices.contains(sender.tag) else { return }
        canvas.setStyle(width: widths[sender.tag] * canvas.widthScale)
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    @objc private func chooseFontSize(_ sender: NSComboBox) {
        applyFontSize(sender.stringValue)
        window?.makeFirstResponder(canvas.preferredResponder)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let value = fontSizePicker.objectValueOfSelectedItem as? String else { return }
        applyFontSize(value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        applyFontSize(fontSizePicker.stringValue)
    }

    private func applyFontSize(_ value: String) {
        guard canvas.styleTool == .text, !isSaving else { return }
        if let size = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           AnnotationFontSize.range.contains(size), CGFloat(size) != canvas.styleWidth {
            canvas.setStyle(width: CGFloat(size))
        }
        syncFontSize()
    }

    private func syncFontSize() {
        fontSizePicker.stringValue = String(Int(canvas.styleWidth))
    }

    private func finishFontSizeEntry() {
        if fontSizePicker.currentEditor() != nil {
            window?.makeFirstResponder(canvas.preferredResponder)
        }
    }

    private func syncStyleButtons() {
        let tool = canvas.styleTool
        for button in groupButtons { button.selected = button.tag == tool.group.rawValue }
        for (group, view) in variantGroups { view.isHidden = group != tool.group }
        for button in variantButtons { button.selected = button.tag == tool.rawValue }
        for button in colorButtons { button.selected = colors[button.tag].1 == canvas.styleColor }
        let widths = tool.widthOptions
        widthGroup?.isHidden = widths.isEmpty
        fontSizeGroup?.isHidden = tool != .text
        if tool == .text, fontSizePicker.currentEditor() == nil { syncFontSize() }
        for button in widthButtons {
            let index = button.tag
            button.selected = widths.indices.contains(index) && widths[index] * canvas.widthScale == canvas.styleWidth
        }
    }

    @objc private func chooseZoom() {
        let zooms: [CGFloat?] = [nil, 0.5, 1, 2]
        guard zooms.indices.contains(zoomPicker.indexOfSelectedItem) else { return }
        finishFontSizeEntry()
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
        for button in groupButtons + variantButtons + colorButtons + widthButtons { button.isEnabled = !isSaving }
        fontSizePicker.isEnabled = !isSaving
        zoomPicker.isEnabled = !isSaving
        window?.isDocumentEdited = hasChanges
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }

    @objc func undo(_ sender: Any?) {
        guard !isSaving else { return }
        finishFontSizeEntry()
        canvas.finishText()
        canvas.resetSelection()
        history.undo()
        updateState()
    }

    @objc func redo(_ sender: Any?) {
        guard !isSaving else { return }
        finishFontSizeEntry()
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
        finishFontSizeEntry()
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
        finishFontSizeEntry()
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
