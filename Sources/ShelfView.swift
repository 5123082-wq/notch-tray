// Notch Tray — GPL-3.0, modified 2026-11-09.
// Native drag lifecycle adapted from boring.notch ShelfItemView.swift.
import AppKit
import QuickLookThumbnailing
import QuartzCore

private let accent = NSColor(calibratedRed: 0.56, green: 0.91, blue: 0.73, alpha: 1)

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ShelfScrollView: NSScrollView {
    // The shelf buffers wheel events while deciding the axis. AppKit's
    // concurrent responsive-scrolling tracker would take over that event stream
    // midway through replay. Use its supported opt-out: standard main-thread
    // scrolling still handles native deltas, phases, elasticity and momentum.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

final class ShelfToolbarButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class FileRemoveButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        NSColor(calibratedWhite: isHighlighted ? 0.38 : 0.18, alpha: 1).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
        let cross = NSBezierPath()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        cross.move(to: NSPoint(x: center.x - 2.5, y: center.y - 2.5))
        cross.line(to: NSPoint(x: center.x + 2.5, y: center.y + 2.5))
        cross.move(to: NSPoint(x: center.x - 2.5, y: center.y + 2.5))
        cross.line(to: NSPoint(x: center.x + 2.5, y: center.y - 2.5))
        cross.lineWidth = 1.25
        cross.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        cross.stroke()
    }
}

// Each page owns its vertical scroll, tiles and empty state throughout paging.
final class ShelfPageContent: NSView {
    override var isFlipped: Bool { true }
    let section: ShelfSection
    let scroll = ShelfScrollView()
    let grid = FlippedView()
    let emptyTitle = label("", size: 17, weight: .medium)
    let emptyHint = label("", size: 12, color: .secondaryLabelColor)
    let emptyIcon = NSImageView()
    private(set) var tiles: [FileTile] = []
    private var scrollOriginToRestore: NSPoint?
    var onScroll: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(section: ShelfSection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        // The shelf chooses the axis before forwarding a complete vertical stream.
        scroll.usesPredominantAxisScrolling = false
        scroll.documentView = grid
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in self?.onScroll?() }
        let shots = section == .screenshots
        emptyTitle.stringValue = shots ? "Скриншоты появятся здесь" : "Оставь файлы здесь"
        emptyHint.stringValue = shots ? "⇧⌘4 — область · ⇧⌘3 — весь экран" : "Затем перетащи их в другое приложение"
        emptyIcon.image = NSImage(systemSymbolName: shots ? "camera" : "tray.and.arrow.down",
            accessibilityDescription: shots ? "Скриншоты" : "Перетащить файлы")
        emptyIcon.contentTintColor = accent
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.unregisterDraggedTypes()
        for view in [emptyTitle, emptyHint, emptyIcon] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func reload(entries: [TrayEntry], controller: TrayController) {
        if tiles.map(\.entry) != entries {
            scrollOriginToRestore = scrollOriginToRestore ?? scroll.contentView.bounds.origin
            tiles.forEach { $0.removeFromSuperview() }
            tiles = entries.map { entry in
                let tile = FileTile(entry: entry, url: controller.url(for: entry))
                tile.controller = controller
                grid.addSubview(tile)
                return tile
            }
        }
        let selected = controller.selectedIDs(in: section)
        for tile in tiles { tile.selected = selected.contains(tile.entry.id) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        let empty = tiles.isEmpty
        scroll.isHidden = empty
        emptyTitle.isHidden = !empty
        emptyHint.isHidden = !empty
        emptyIcon.isHidden = !empty
        emptyIcon.frame = NSRect(x: width / 2 - 16, y: 6, width: 32, height: 32)
        emptyTitle.frame = NSRect(x: 20, y: 46, width: width - 40, height: 24)
        emptyHint.frame = NSRect(x: 20, y: 73, width: width - 40, height: 20)
        emptyTitle.alignment = .center
        emptyHint.alignment = .center
        scroll.frame = NSRect(x: 18, y: 0, width: width - 36, height: bounds.height)
        let columns = max(1, Int((width - 40) / 100))
        let cellWidth = (width - 40) / CGFloat(columns)
        let rows = max(1, Int(ceil(Double(tiles.count) / Double(columns))))
        grid.frame = NSRect(x: 0, y: 0, width: width - 36, height: CGFloat(rows) * 112)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * cellWidth + 2,
                y: CGFloat(index / columns) * 112 + 2, width: cellWidth - 5, height: 108)
        }
        if let origin = scrollOriginToRestore {
            scrollOriginToRestore = nil
            let limit = max(0, grid.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, origin.y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

final class ShelfView: DropSurface {
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    let subtitle = label("", size: 11, color: .secondaryLabelColor)
    private let pages: [ShelfSection: ShelfPageContent] = [
        .files: ShelfPageContent(section: .files), .screenshots: ShelfPageContent(section: .screenshots)
    ]
    private let pageViewport = FlippedView()
    func page(for section: ShelfSection) -> ShelfPageContent { pages[section]! }
    private var activePage: ShelfPageContent { page(for: controller?.activeSection ?? .files) }
    var scroll: NSScrollView { activePage.scroll }
    var grid: FlippedView { activePage.grid }
    var tiles: [FileTile] { activePage.tiles }
    var emptyTitle: NSTextField { activePage.emptyTitle }
    var emptyHint: NSTextField { activePage.emptyHint }
    var emptyIcon: NSImageView { activePage.emptyIcon }
    let addButton = ShelfToolbarButton()
    let menuButton = ShelfToolbarButton()
    let pathButton = ShelfToolbarButton()
    let filesButton = ShelfToolbarButton()
    let screenshotsButton = ShelfToolbarButton()
    let spinner = NSProgressIndicator()
    private let toolbarDivider = NSBox()
    private let content = FlippedView()
    private let surface = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let revealMask = CAShapeLayer()
    private var scrollEventMonitor: Any?
    private var sectionSwipe = ShelfSwipeGesture()
    private var displayedSection: ShelfSection?
    private var paging = ShelfPagingMotion()
    private var pagingDisplayLink: CADisplayLink?
    private var pagingFrameTime: CFTimeInterval?
    private var pendingScrollEvents: [NSEvent] = []
    private var ownsScrollSequence = false
    private var dragOriginSection = 0
    private var horizontalTranslation = 0.0
    private var horizontalSamples: [(time: TimeInterval, x: Double)] = []
    private var committingPageTarget = false
    // Optional observation seam for tests; real events otherwise go to NSScrollView.
    var forwardVerticalScroll: ((NSEvent) -> Void)?
    var sectionPosition: Double { paging.position }
    var isSectionMoving: Bool { paging.isDragging || paging.isSettling }
    private var activePageIndex: Int { controller?.activeSection == .screenshots ? 1 : 0 }
    private var reducedSectionMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var expansion: Double = 0
    private(set) var hoveredEntryID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(surface)
        layer?.addSublayer(edge)
        layer?.mask = revealMask
        surface.fillColor = NSColor.black.cgColor
        edge.fillColor = nil
        edge.strokeColor = accent.withAlphaComponent(0.75).cgColor
        edge.lineWidth = 2
        content.wantsLayer = true
        addSubview(content)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notch Tray — файлы и скриншоты")
        content.addSubview(subtitle)
        pageViewport.wantsLayer = true
        pageViewport.layer?.masksToBounds = true
        content.addSubview(pageViewport)
        for page in pages.values {
            page.onScroll = { [weak self] in self?.updateHover() }
            pageViewport.addSubview(page)
        }
        configure(addButton, symbol: "plus", tooltip: "Добавить файлы…", action: #selector(addFiles))
        configure(menuButton, symbol: "ellipsis", tooltip: "Действия с полкой", action: #selector(showMenu))
        configure(pathButton, symbol: "folder", tooltip: "Перейти к папке… (⌘⇧G) в активном приложении", action: #selector(goToFolder))
        pathButton.title = "⇧⌘G"
        pathButton.imagePosition = .imageLeading
        pathButton.font = .systemFont(ofSize: 11, weight: .medium)
        pathButton.setAccessibilityLabel("Перейти к папке в активном приложении")
        pathButton.setAccessibilityHelp("Открывает ввод пути в Finder или в окне открытия и сохранения файлов. Сочетание клавиш Command–Shift–G.")
        configure(filesButton, symbol: "tray", tooltip: "Файлы", action: #selector(showFiles))
        configure(screenshotsButton, symbol: "camera", tooltip: "Скриншоты", action: #selector(showScreenshots))
        for button in [filesButton, screenshotsButton] {
            button.setButtonType(.toggle)
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
        }
        screenshotsButton.imagePosition = .imageLeading
        screenshotsButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        toolbarDivider.boxType = .separator
        content.addSubview(toolbarDivider)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollEventMonitor { NSEvent.removeMonitor(scrollEventMonitor) }
        scrollEventMonitor = nil
        resetSectionInput()
        finishSectionTransition()
        guard window != nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleSectionScroll(event) == true ? nil : event
        }
    }

    @discardableResult
    func handleSectionScroll(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, let window, event.window === window,
              let controller, controller.isExpanded, expansion >= 0.99,
              controller.canSwitchSections,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            resetSectionInput()
            if paging.isDragging { cancelSectionDrag() }
            return false
        }
        let phase: ShelfSwipeGesture.Phase
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.stationary) { phase = .stationary }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else { phase = .none }
        let momentum = !event.momentumPhase.isEmpty
        if phase == .began && !momentum {
            guard visibleBody.contains(convert(event.locationInWindow, from: nil)) else {
                resetSectionInput()
                if paging.isDragging { cancelSectionDrag() }
                return false
            }
            ownsScrollSequence = true
            pendingScrollEvents.removeAll(keepingCapacity: true)
            if event.hasPreciseScrollingDeltas && isSectionMoving {
                // A fresh touch catches the strip where it is visible, even
                // while its direction is still being determined.
                paging.beginDrag()
                pagingDisplayLink?.invalidate(); pagingDisplayLink = nil; pagingFrameTime = nil
            }
        }
        guard ownsScrollSequence else { return false }
        let decision = sectionSwipe.consume(deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY), phase: phase,
            isMomentum: momentum, isPrecise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp)
        switch decision.route {
        case .ignore:
            resetSectionInput()
            if paging.isDragging { cancelSectionDrag() }
            return false
        case .pending:
            // Neither page nor vertical content moves until the same evidence
            // threshold chooses an axis. No first-pixel race with NSScrollView.
            if decision.ended {
                pendingScrollEvents.removeAll(); ownsScrollSequence = false
                if paging.isDragging { cancelSectionDrag() }
            }
            else { pendingScrollEvents.append(event) }
            return true
        case .vertical:
            if decision.didResolve {
                if paging.isDragging { cancelSectionDrag() }
                pendingScrollEvents.append(event)
                let buffered = pendingScrollEvents
                pendingScrollEvents.removeAll(keepingCapacity: true)
                for item in buffered { deliverVerticalScroll(item) }
            } else { deliverVerticalScroll(event) }
            if decision.cancelled { ownsScrollSequence = false }
            return true
        case .horizontal:
            if momentum { return true } // The settling spring owns release motion.
            if decision.didResolve {
                dragOriginSection = activePageIndex
                paging.beginDrag()
                pagingDisplayLink?.invalidate(); pagingDisplayLink = nil; pagingFrameTime = nil
                horizontalTranslation = decision.displacementX
                let start = pendingScrollEvents.first?.timestamp ?? event.timestamp
                horizontalSamples = [(event.timestamp, horizontalTranslation)]
                if event.timestamp - start > 0.001 { horizontalSamples.insert((start, 0), at: 0) }
                pendingScrollEvents.removeAll(keepingCapacity: true)
                paging.drag(contentDeltaX: decision.displacementX, pageWidth: Double(pageViewport.bounds.width))
                clearHover()
            } else if !decision.ended {
                horizontalTranslation += Double(event.scrollingDeltaX)
                horizontalSamples.append((event.timestamp, horizontalTranslation))
                while horizontalSamples.count > 2 && event.timestamp - horizontalSamples[0].time > 0.09 {
                    horizontalSamples.removeFirst()
                }
                paging.drag(contentDeltaX: Double(event.scrollingDeltaX), pageWidth: Double(pageViewport.bounds.width))
            }
            if decision.ended {
                let velocity = releaseVelocity(at: event.timestamp)
                paging.endDrag(velocityContentX: velocity, pageWidth: Double(pageViewport.bounds.width),
                    cancelled: decision.cancelled, originSection: dragOriginSection,
                    reduceMotion: reducedSectionMotion)
                committingPageTarget = true
                controller.switchSection(paging.targetIndex == 0 ? .files : .screenshots)
                committingPageTarget = false
                if decision.cancelled { ownsScrollSequence = false }
                startSectionSettling()
            }
            renderSectionPosition()
            return true
        }
    }
    private func deliverVerticalScroll(_ event: NSEvent) {
        if let forwardVerticalScroll { forwardVerticalScroll(event) }
        else if !scroll.isHidden { scroll.scrollWheel(with: event) }
    }
    private func releaseVelocity(at time: TimeInterval) -> Double {
        guard let first = horizontalSamples.first, let last = horizontalSamples.last,
              time - last.time < 0.1, last.time - first.time > 0.001 else { return 0 }
        return min(3000, max(-3000, (last.x - first.x) / (last.time - first.time)))
    }
    private func resetSectionInput() {
        sectionSwipe.reset()
        pendingScrollEvents.removeAll(keepingCapacity: true)
        horizontalSamples.removeAll(keepingCapacity: true)
        ownsScrollSequence = false
    }
    private func cancelSectionDrag() {
        paging.endDrag(velocityContentX: 0, pageWidth: Double(pageViewport.bounds.width),
            cancelled: true, originSection: activePageIndex, reduceMotion: reducedSectionMotion)
        startSectionSettling()
    }
    private func startSectionSettling() {
        if reducedSectionMotion || !paging.isSettling {
            paging.finish(); renderSectionPosition(); return
        }
        guard pagingDisplayLink == nil, let window else { return }
        pagingFrameTime = nil
        let link = window.displayLink(target: self, selector: #selector(animateSection(_:)))
        pagingDisplayLink = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func animateSection(_ link: CADisplayLink) {
        let elapsed = pagingFrameTime.map { link.timestamp - $0 } ?? 1.0 / 120.0
        pagingFrameTime = link.timestamp
        advanceSectionMotion(seconds: min(0.05, max(0, elapsed)))
    }
    func advanceSectionMotion(seconds: Double) {
        if reducedSectionMotion { paging.finish() }
        else { paging.advance(seconds: seconds) }
        renderSectionPosition()
    }
    func finishSectionTransition() {
        paging.retarget(index: activePageIndex, reduceMotion: true)
        renderSectionPosition()
    }
    private func renderSectionPosition() {
        let moving = isSectionMoving && !reducedSectionMotion
        let position = reducedSectionMotion ? Double(activePageIndex) : paging.position
        if !moving {
            pagingDisplayLink?.invalidate(); pagingDisplayLink = nil; pagingFrameTime = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, section) in [ShelfSection.files, .screenshots].enumerated() {
            let page = page(for: section)
            page.isHidden = !moving && index != activePageIndex
            // Move the view, keeping AppKit clipping, accessibility and event
            // coordinates aligned with its cached backing layer. Only a resize
            // needs layout; the gesture changes origins without rebuilding tiles.
            if page.frame.size != pageViewport.bounds.size { page.setFrameSize(pageViewport.bounds.size) }
            page.setFrameOrigin(NSPoint(x: (CGFloat(index) - CGFloat(position)) * pageViewport.bounds.width, y: 0))
        }
        CATransaction.commit()
        if !moving { updateHover() }
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        content.addSubview(button)
    }

    func reload() {
        guard let controller else { return }
        clearHover()
        for section in [ShelfSection.files, .screenshots] {
            page(for: section).reload(entries: controller.entries(in: section), controller: controller)
        }
        if displayedSection != controller.activeSection {
            let wasInitialized = displayedSection != nil
            displayedSection = controller.activeSection
            if !committingPageTarget {
                resetSectionInput()
                paging.retarget(index: activePageIndex,
                    reduceMotion: !wasInitialized || !controller.isExpanded || reducedSectionMotion)
                startSectionSettling()
            }
        }
        updateState()
    }
    func updateSelection() {
        guard let controller else { return }
        for section in [ShelfSection.files, .screenshots] {
            let selection = controller.selectedIDs(in: section)
            for tile in page(for: section).tiles { tile.selected = selection.contains(tile.entry.id) }
        }
    }
    func updateSelectionFocus() {
        guard let controller else { return }
        let panel = controller.panel
        let active = controller.isExpanded && controller.canSwitchSections &&
            ((panel.isKeyWindow && panel.firstResponder === self) || panel.previewWindow?.isKeyWindow == true)
        for section in [ShelfSection.files, .screenshots] {
            for tile in page(for: section).tiles { tile.selectionActive = active && section == controller.activeSection }
        }
    }
    func revealCard(_ id: UUID) {
        layoutSubtreeIfNeeded()
        guard let tile = activePage.tiles.first(where: { $0.entry.id == id }) else { return }
        tile.scrollToVisible(tile.bounds)
    }
    func updateState() {
        guard let controller else { return }
        let screenshots = controller.activeSection == .screenshots
        let activity = controller.busy > 0 || controller.hasError
        addButton.isHidden = screenshots
        toolbarDivider.isHidden = screenshots
        subtitle.stringValue = activity ? controller.statusText : (screenshots ? controller.screenshotStatusText : "")
        subtitle.toolTip = subtitle.stringValue.isEmpty ? nil : subtitle.stringValue
        subtitle.textColor = controller.hasError ? .systemOrange : .secondaryLabelColor
        pathButton.isEnabled = !controller.choosingFiles && !controller.isDraggingOut && !controller.incomingDrag
        let canSwitch = controller.canSwitchSections
        updateSelectionFocus()
        if !controller.isExpanded || !canSwitch {
            resetSectionInput()
            finishSectionTransition()
        }
        for (button, selected) in [(filesButton, !screenshots), (screenshotsButton, screenshots)] {
            button.isEnabled = canSwitch
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? accent : .secondaryLabelColor
        }
        let count = controller.screenshotCount
        screenshotsButton.title = count == 0 ? "" : (count > 99 ? "99+" : String(count))
        screenshotsButton.imagePosition = count == 0 ? .imageOnly : .imageLeading
        screenshotsButton.toolTip = count == 0 ? "Скриншоты · ⇧⌘4 — снимок области" : "Скриншоты: \(count)"
        screenshotsButton.setAccessibilityLabel("Скриншоты, \(count)")
        screenshotsButton.setAccessibilityHelp("Новые системные снимки появляются здесь. Настройки приёма находятся в меню «…».")
        if !screenshots && count > 0 { screenshotsButton.contentTintColor = .white }
        updateHover()
        if controller.busy > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
        updateReveal()
    }
    var visibleBody: NSRect {
        guard let controller else { return .zero }
        let progress = CGFloat(min(1, max(0, expansion)))
        let closed = controller.geometry.closedSize
        let open = controller.geometry.openSize
        let size = NSSize(width: closed.width + (open.width - closed.width) * progress,
                          height: closed.height + (open.height - closed.height) * progress)
        return NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }
    func present(expansion: Double) {
        self.expansion = min(1, max(0, expansion))
        if expansion == 0 { resetSectionInput(); finishSectionTransition() }
        updateReveal()
        updateHover()
    }
    // One owner for hover: individual tiles never retain enter/exit state.
    // The existing mouse monitor supplies screen coordinates even when another
    // application is active. Layout and scrolling also re-evaluate the pointer.
    func updateHover(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        guard let controller, let window, controller.isExpanded, expansion >= 0.99,
              !controller.isDraggingOut, !controller.incomingDrag,
              !controller.externalDragActive, !controller.choosingFiles,
              !scroll.isHidden, !isSectionMoving else { clearHover(); return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let clipPoint = scroll.contentView.convert(point, from: self)
        guard visibleBody.contains(point), scroll.contentView.bounds.contains(clipPoint) else {
            clearHover()
            return
        }
        let hovered = tiles.first { tile in
            tile.bounds.contains(tile.convert(point, from: self))
        }
        setHoveredEntry(hovered?.entry.id)
    }
    func clearHover() { setHoveredEntry(nil) }
    private func setHoveredEntry(_ id: UUID?) {
        guard hoveredEntryID != id else { return }
        hoveredEntryID = id
        for tile in pages.values.flatMap(\.tiles) where tile.entry.id != id { tile.setHovered(false) }
        tiles.first(where: { $0.entry.id == id })?.setHovered(true)
    }
    private func outline(_ rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let radius: CGFloat = min(22, rect.height / 2)
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: NSPoint(x: rect.maxX - radius, y: rect.maxY), control: NSPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: NSPoint(x: rect.minX, y: rect.maxY - radius), control: NSPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
    private func updateReveal() {
        guard let controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let body = visibleBody
        surface.path = outline(body)
        surface.opacity = Float(TrayMotion.surfaceOpacity(at: expansion))
        edge.path = outline(body.insetBy(dx: 1, dy: 1))
        edge.opacity = controller.incomingDrag ? Float(TrayMotion.surfaceOpacity(at: expansion)) : 0
        revealMask.frame = bounds
        revealMask.path = outline(body)
        content.frame = NSRect(x: (bounds.width - controller.geometry.openSize.width) / 2,
                               y: -8 * (1 - CGFloat(expansion)),
                               width: controller.geometry.openSize.width, height: controller.geometry.openSize.height)
        content.alphaValue = TrayMotion.contentOpacity(at: expansion)
        content.isHidden = expansion == 0
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        guard let controller else { return }
        let top = controller.geometry.notchHeight + 8
        // Content is always laid out at its final width. Only the reveal clips it.
        let width = controller.geometry.openSize.width
        updateReveal()
        let toolbarY = controller.geometry.openSize.height - 36
        let compact = width < 440
        pathButton.imagePosition = compact ? .imageOnly : .imageLeading
        pathButton.frame = NSRect(x: 20, y: toolbarY, width: compact ? 28 : 76, height: 28)
        filesButton.frame = NSRect(x: compact ? 62 : 110, y: toolbarY, width: 34, height: 28)
        screenshotsButton.frame = NSRect(x: compact ? 102 : 150, y: toolbarY, width: compact ? 52 : 60, height: 28)
        toolbarDivider.frame = NSRect(x: width - 94, y: toolbarY + 6, width: 1, height: 16)
        addButton.frame = NSRect(x: width - 83, y: toolbarY, width: 28, height: 28)
        menuButton.frame = NSRect(x: width - 49, y: toolbarY, width: 28, height: 28)
        let statusX: CGFloat = compact ? 184 : 242
        let statusTrailing: CGFloat = addButton.isHidden ? 60 : 106
        subtitle.frame = NSRect(x: statusX, y: toolbarY + 6, width: max(0, width - statusX - statusTrailing), height: 16)
        spinner.frame = NSRect(x: compact ? 164 : 222, y: toolbarY + 6, width: 14, height: 14)
        pageViewport.frame = NSRect(x: 0, y: top, width: width, height: toolbarY - top - 8)
        renderSectionPosition()
        for page in pages.values { page.layoutSubtreeIfNeeded() }
        updateHover()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // A drag destination must exist from the first reveal frame, including
        // over labels, buttons and thumbnails. The visual mask only clips paint.
        if controller?.externalDragActive == true || controller?.incomingDrag == true {
            return bounds.contains(local) ? self : nil
        }
        guard expansion > 0, visibleBody.contains(local) else { return nil }
        if isSectionMoving, pageViewport.frame.contains(content.convert(local, from: self)) {
            // Consume the click that settles the strip so it cannot select a different file under
            // the pointer. Fresh scroll input still re-grabs through the monitor.
            if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .rightMouseDown {
                resetSectionInput()
                finishSectionTransition()
            }
            return self
        }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { controller?.showPinned() }
    override func selectAll(_ sender: Any?) { controller?.selectAll() }
    override func keyDown(with event: NSEvent) {
        if event.isUnmodifiedSpace {
            if !event.isARepeat { controller?.previewSelection() }
            return
        }
        if event.keyCode == 53 { controller?.collapse(); return }
        if event.keyCode == 51 || event.keyCode == 117 { controller?.removeSelected(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            controller?.selectAll(); return
        }
        super.keyDown(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
    @objc private func addFiles() { controller?.chooseFiles() }
    @objc private func showMenu() { controller?.showShelfMenu(from: menuButton) }
    @objc private func goToFolder() { controller?.goToFolder() }
    @objc private func showFiles() { controller?.switchSection(.files) }
    @objc private func showScreenshots() { controller?.switchSection(.screenshots) }
    deinit {
        if let scrollEventMonitor { NSEvent.removeMonitor(scrollEventMonitor) }
        pagingDisplayLink?.invalidate()
    }
}

final class FileTile: DropSurface, NSDraggingSource {
    let entry: TrayEntry
    let fileURL: URL
    let icon = NSImageView()
    let nameField = label("", size: 11)
    let removeButton = FileRemoveButton()
    var selected = false { didSet { needsDisplay = true } }
    var selectionActive = false { didSet { if selectionActive != oldValue, selected { needsDisplay = true } } }
    private var down: NSEvent?
    private var didDrag = false
    private var outgoingIDs = Set<UUID>()
    private var request: QLThumbnailGenerator.Request?
    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init(entry: TrayEntry, url: URL) {
        self.entry = entry
        fileURL = url
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        nameField.stringValue = entry.name
        nameField.alignment = .center
        nameField.maximumNumberOfLines = 2
        nameField.cell?.wraps = true
        nameField.lineBreakMode = .byTruncatingMiddle
        addSubview(nameField)
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.setButtonType(.momentaryChange)
        removeButton.toolTip = "Убрать с полки"
        removeButton.setAccessibilityLabel("Убрать «\(entry.name)» с полки")
        removeButton.target = self
        removeButton.action = #selector(removeThisFile)
        removeButton.isHidden = true
        addSubview(removeButton)
        toolTip = entry.name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name)
        setAccessibilityHelp("Пробел — быстрый просмотр выбранного файла. ⌘ — выбрать несколько. Перетащите файл в другое приложение.")
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 52, height: 52), scale: 2, representationTypes: .thumbnail)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
            guard let result else { return }
            DispatchQueue.main.async { self?.icon.image = result.nsImage }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: bounds.midX - 24, y: 10, width: 48, height: 48)
        nameField.frame = NSRect(x: 5, y: 65, width: bounds.width - 10, height: 33)
        removeButton.frame = NSRect(x: 1, y: 1, width: 24, height: 24)
    }
    func setHovered(_ hovered: Bool) {
        guard removeButton.isHidden == hovered else { return }
        removeButton.isHidden = !hovered
        // Invalidate the old button footprint as well as the button itself.
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor.white.withAlphaComponent(selectionActive ? 0.12 : 0.07).setFill()
            shape.fill()
            if selectionActive {
                accent.withAlphaComponent(0.5).setStroke()
                shape.stroke()
            }
        }
    }
    // Only the remove control intercepts clicks; thumbnails still drag as one tile.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !removeButton.isHidden, removeButton.frame.contains(local) { return removeButton }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        down = event
        didDrag = false
        window?.makeFirstResponder(controller?.view)
        controller?.select(entry.id, modifiers: event.modifierFlags)
        if event.clickCount == 2 { controller?.open(entry) }
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            controller?.selectOnly(entry.id)
        }
        down = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let controller, !didDrag else { return }
        guard hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 3 else { return }
        let entries = controller.dragItems(for: entry.id)
        var dragging: [NSDraggingItem] = []
        for entry in entries {
            let url = controller.url(for: entry)
            guard FileManager.default.fileExists(atPath: url.path) else {
                controller.report("Файл «\(entry.name)» недоступен.")
                return
            }
            // File URLs only: some apps otherwise paste text paths instead of attachments.
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let preview = entry.id == self.entry.id ? icon.image : NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(icon.frame, contents: preview)
            dragging.append(item)
        }
        guard !dragging.isEmpty else { return }
        didDrag = true
        outgoingIDs = Set(entries.map(\.id))
        self.down = nil
        controller.isDraggingOut = true
        let session = beginDraggingSession(with: dragging, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        let ids = outgoingIDs
        outgoingIDs.removeAll()
        controller?.isDraggingOut = false
        controller?.outgoingFinished(success: operation == .copy, ids: ids)
    }
    override func rightMouseDown(with event: NSEvent) {
        controller?.select(entry.id, modifiers: [])
        let menu = NSMenu()
        if controller?.canEdit(entry) == true {
            let edit = NSMenuItem(title: "Редактировать", action: #selector(editImage), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            menu.addItem(.separator())
        }
        for (title, action) in [("Открыть копию", #selector(openCopy)), ("Показать копию в Finder", #selector(revealCopy)), ("Убрать с полки", #selector(removeCopy))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openCopy() { controller?.open(entry) }
    @objc private func editImage() { controller?.editImage(entry.id) }
    @objc private func revealCopy() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    @objc private func removeCopy() { controller?.removeSelected() }
    @objc private func removeThisFile() { controller?.removeEntry(entry.id) }
    deinit { if let request { QLThumbnailGenerator.shared.cancel(request) } }
}
