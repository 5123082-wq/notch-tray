// Image annotations in top-left pixel coordinates. GPL-3.0.
import AppKit

enum AnnotationTool: Int {
    case arrow, openArrow, doubleArrow, frame, circle, line, pen, marker, highlighter, text

    enum Group: Int, CaseIterable {
        case arrows, shapes, freehand, text

        var title: String {
            switch self {
            case .arrows: return "Стрелки"
            case .shapes: return "Фигуры"
            case .freehand: return "Линии от руки"
            case .text: return "Текст"
            }
        }

        var tools: [AnnotationTool] {
            switch self {
            case .arrows: return [.arrow, .openArrow, .doubleArrow]
            case .shapes: return [.frame, .circle, .line]
            case .freehand: return [.pen, .marker, .highlighter]
            case .text: return [.text]
            }
        }
    }

    var group: Group {
        switch self {
        case .arrow, .openArrow, .doubleArrow: return .arrows
        case .frame, .circle, .line: return .shapes
        case .pen, .marker, .highlighter: return .freehand
        case .text: return .text
        }
    }

    var widthOptions: [CGFloat] {
        switch self {
        case .marker, .text: return []
        case .highlighter: return [10, 18, 28]
        default: return [2, 4, 7]
        }
    }

    var title: String {
        switch self {
        case .arrow: return "Залитая"
        case .openArrow: return "Открытая"
        case .doubleArrow: return "Двусторонняя"
        case .frame: return "Рамка"
        case .circle: return "Круг"
        case .line: return "Линия"
        case .pen: return "Карандаш"
        case .marker: return "Маркер"
        case .highlighter: return "Выделитель"
        case .text: return "Текст"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .openArrow: return "chevron.right"
        case .doubleArrow: return "arrow.left.and.right"
        case .frame: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .marker: return "paintbrush.pointed"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        }
    }
}

enum AnnotationHandle: Equatable {
    enum Axis: CaseIterable {
        case minimum, middle, maximum

        var opposite: Axis {
            switch self {
            case .minimum: return .maximum
            case .middle: return .middle
            case .maximum: return .minimum
            }
        }

        func position(from minimum: CGFloat, to maximum: CGFloat) -> CGFloat {
            switch self {
            case .minimum: return minimum
            case .middle: return (minimum + maximum) / 2
            case .maximum: return maximum
            }
        }

        func resized(minimum: CGFloat, maximum: CGFloat, by delta: CGFloat,
                     minimumSize: CGFloat) -> (CGFloat, CGFloat) {
            let span = min(minimumSize, maximum - minimum)
            switch self {
            case .minimum: return (min(maximum - span, minimum + delta), maximum)
            case .middle: return (minimum, maximum)
            case .maximum: return (minimum, max(minimum + span, maximum + delta))
            }
        }
    }

    case start, tip, frame(x: Axis, y: Axis)

    var cursor: NSCursor {
        guard case let .frame(x, y) = self else { return .crosshair }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (x, y) {
            case (.minimum, .minimum): position = .topLeft
            case (.minimum, .middle): position = .left
            case (.minimum, .maximum): position = .bottomLeft
            case (.middle, .minimum): position = .top
            case (.middle, .maximum): position = .bottom
            case (.maximum, .minimum): position = .topRight
            case (.maximum, .middle): position = .right
            case (.maximum, .maximum): position = .bottomRight
            case (.middle, .middle): return .crosshair
            }
            return .frameResize(position: position, directions: .all)
        }
        if x == .middle { return .resizeUpDown }
        if y == .middle { return .resizeLeftRight }
        return .crosshair
    }
}

struct ImageAnnotation: Equatable {
    enum ArrowStyle: Equatable { case filled, open, double }
    enum FreehandStyle: Equatable { case pencil, marker, highlighter }

    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint, style: ArrowStyle = .filled)
        case frame(CGRect)
        case circle(center: CGPoint, radius: CGFloat)
        case line(CGPoint, CGPoint)
        case pen([CGPoint], style: FreehandStyle = .pencil)
        case text(String, CGPoint)
    }

    var shape: Shape
    var color: CGColor
    // Stroke width for drawing tools and font size for text, in image pixels.
    var width: CGFloat

    var tool: AnnotationTool {
        switch shape {
        case .arrow(_, _, .filled): return .arrow
        case .arrow(_, _, .open): return .openArrow
        case .arrow(_, _, .double): return .doubleArrow
        case .frame: return .frame
        case .circle: return .circle
        case .line: return .line
        case .pen(_, .pencil): return .pen
        case .pen(_, .marker): return .marker
        case .pen(_, .highlighter): return .highlighter
        case .text: return .text
        }
    }

    private var fillsPath: Bool {
        if case .arrow(_, _, let style) = shape { return style != .open }
        return false
    }

    private var path: CGPath {
        let path = CGMutablePath()
        switch shape {
        case .arrow(let start, let end, let style):
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { return path }
            let dx = (end.x - start.x) / length, dy = (end.y - start.y) / length
            let head = min(width * 3.5, length * (style == .double ? 0.45 : 0.6))
            let base = CGPoint(x: end.x - dx * head, y: end.y - dy * head)
            func offset(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
                CGPoint(x: point.x - dy * distance, y: point.y + dx * distance)
            }
            let shaft = min(width / 2, head / 3)
            if style == .open {
                path.addLines(between: [start, end])
                path.addLines(between: [offset(base, by: head / 2), end, offset(base, by: -head / 2)])
            } else {
                let tail = style == .double ? CGPoint(x: start.x + dx * head, y: start.y + dy * head) : start
                var outline = [offset(tail, by: shaft), offset(base, by: shaft),
                    offset(base, by: head / 2), end, offset(base, by: -head / 2),
                    offset(base, by: -shaft), offset(tail, by: -shaft)]
                if style == .double { outline += [offset(tail, by: -head / 2), start, offset(tail, by: head / 2)] }
                path.addLines(between: outline)
                path.closeSubpath()
            }
        case .frame(let rect):
            path.addRect(rect)
        case .circle(let center, let radius):
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
        case .line(let start, let end):
            path.move(to: start)
            path.addLine(to: end)
        case .pen(let points, _):
            path.addLines(between: points)
        case .text:
            break
        }
        return path
    }

    var bounds: CGRect {
        if case .text(let text, let point) = shape {
            return CGRect(origin: point, size: AnnotationTextLayout(text, fontSize: width, color: color).size)
        }
        let outline = path.boundingBoxOfPath
        // Round caps and joins add half a stroke on each axis. Using the
        // outline copied by Core Graphics introduces subpixel Bézier overshoot.
        return fillsPath ? outline : outline.insetBy(dx: -width / 2, dy: -width / 2)
    }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if case .text(let text, let point) = shape {
            AnnotationTextLayout(text, fontSize: width, color: color).draw(at: point, in: context)
            return
        }
        let ink = tool == .highlighter ? color.copy(alpha: color.alpha * 0.38) ?? color : color
        context.addPath(path)
        if fillsPath {
            context.setFillColor(ink)
            context.fillPath()
        } else {
            context.setStrokeColor(ink)
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    func hit(_ point: CGPoint, margin: CGFloat) -> Bool {
        if case .text = shape { return bounds.insetBy(dx: -margin, dy: -margin).contains(point) }
        let outline = path
        let reach = width / 2 + margin
        guard outline.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).contains(point) else { return false }
        if fillsPath, outline.contains(point) { return true }
        return outline.copy(strokingWithWidth: width + margin * 2,
                            lineCap: .round, lineJoin: .round, miterLimit: 4).contains(point)
    }

    var handles: [(kind: AnnotationHandle, point: CGPoint)] {
        switch shape {
        case .arrow(let start, let end, _), .line(let start, let end):
            return [(.start, start), (.tip, end)]
        case .circle(let center, let radius):
            return [(.frame(x: .minimum, y: .middle), CGPoint(x: center.x - radius, y: center.y)),
                    (.frame(x: .maximum, y: .middle), CGPoint(x: center.x + radius, y: center.y)),
                    (.frame(x: .middle, y: .minimum), CGPoint(x: center.x, y: center.y - radius)),
                    (.frame(x: .middle, y: .maximum), CGPoint(x: center.x, y: center.y + radius))]
        case .frame, .pen, .text:
            let rect: CGRect
            if case .frame(let frame) = shape { rect = frame } else { rect = bounds }
            return AnnotationHandle.Axis.allCases.flatMap { y in
                AnnotationHandle.Axis.allCases.compactMap { x in
                    guard x != .middle || y != .middle else { return nil }
                    return (.frame(x: x, y: y), CGPoint(
                        x: x.position(from: rect.minX, to: rect.maxX),
                        y: y.position(from: rect.minY, to: rect.maxY)))
                }
            }
        }
    }

    func resized(at handle: AnnotationHandle, by offset: CGPoint, minimumSize: CGFloat) -> ImageAnnotation {
        var annotation = self
        func shift(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        }
        switch (shape, handle) {
        case (.arrow(let start, let end, _), .start), (.arrow(let start, let end, _), .tip),
             (.line(let start, let end), .start), (.line(let start, let end), .tip):
            let a = handle == .start ? shift(start) : start
            let b = handle == .tip ? shift(end) : end
            if a != b {
                if case .arrow(_, _, let style) = shape { annotation.shape = .arrow(a, b, style: style) }
                else { annotation.shape = .line(a, b) }
            }
        case (.circle(let center, let radius), .frame(let x, let y)):
            let horizontal = y == .middle
            let sign: CGFloat = (horizontal ? x : y) == .maximum ? 1 : -1
            let fixed = (horizontal ? center.x : center.y) - sign * radius
            let cross = horizontal ? center.y : center.x
            let diameter = max(min(minimumSize, 2 * radius), 2 * radius + sign * (horizontal ? offset.x : offset.y))
            let mid = fixed + sign * diameter / 2
            annotation.shape = .circle(center: horizontal ? CGPoint(x: mid, y: cross) : CGPoint(x: cross, y: mid),
                                       radius: diameter / 2)
        case (.frame(let rect), .frame(let x, let y)):
            let (left, right) = x.resized(minimum: rect.minX, maximum: rect.maxX, by: offset.x,
                                          minimumSize: minimumSize)
            let (top, bottom) = y.resized(minimum: rect.minY, maximum: rect.maxY, by: offset.y,
                                           minimumSize: minimumSize)
            annotation.shape = .frame(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        case (.pen(let points, let style), .frame(let x, let y)):
            let rect = path.boundingBoxOfPath
            func map(_ value: CGFloat, axis: AnnotationHandle.Axis, lower: CGFloat, upper: CGFloat, delta: CGFloat) -> CGFloat {
                let span = upper - lower
                guard span > 0.001, axis != .middle else { return value }
                let (start, end) = axis.resized(minimum: lower, maximum: upper, by: delta, minimumSize: minimumSize)
                return start + (value - lower) * (end - start) / span
            }
            annotation.shape = .pen(points.map { point in
                CGPoint(x: map(point.x, axis: x, lower: rect.minX, upper: rect.maxX, delta: offset.x),
                        y: map(point.y, axis: y, lower: rect.minY, upper: rect.maxY, delta: offset.y))
            }, style: style)
        case (.text(let value, _), .frame(let x, let y)):
            let rect = bounds
            let fixed = CGPoint(x: x.opposite.position(from: rect.minX, to: rect.maxX),
                                y: y.opposite.position(from: rect.minY, to: rect.maxY))
            let dx = x.position(from: rect.minX, to: rect.maxX) - fixed.x
            let dy = y.position(from: rect.minY, to: rect.maxY) - fixed.y
            let squareLength = dx * dx + dy * dy
            guard squareLength > 0 else { return self }
            // Project the drag onto the handle's axis to keep the font proportional.
            let factor = 1 + (offset.x * dx + offset.y * dy) / squareLength
            let fontSize = AnnotationFontSize.rounded(width * factor)
            guard fontSize != width else { return self }
            let size = AnnotationTextLayout(value, fontSize: fontSize, color: color).size
            let anchor = CGPoint(x: fixed.x - x.opposite.position(from: 0, to: size.width),
                                 y: fixed.y - y.opposite.position(from: 0, to: size.height))
            annotation.width = fontSize
            annotation.shape = .text(value, anchor)
        default:
            break
        }
        return annotation
    }

    func moved(by offset: CGPoint) -> ImageAnnotation {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        }
        var annotation = self
        switch shape {
        case .arrow(let start, let end, let style): annotation.shape = .arrow(move(start), move(end), style: style)
        case .frame(let rect): annotation.shape = .frame(rect.offsetBy(dx: offset.x, dy: offset.y))
        case .circle(let center, let radius): annotation.shape = .circle(center: move(center), radius: radius)
        case .line(let start, let end): annotation.shape = .line(move(start), move(end))
        case .pen(let points, let style): annotation.shape = .pen(points.map(move), style: style)
        case .text(let text, let point): annotation.shape = .text(text, move(point))
        }
        return annotation
    }
}

enum AnnotationArtboard {
    static func bounds(for source: CGRect, annotations: [ImageAnnotation]) -> CGRect {
        annotations.reduce(source) { $0.union($1.bounds) }.integral
    }

    static func drawPadding(in context: CGContext, source: CGRect, artboard: CGRect) {
        guard source != artboard else { return }
        context.saveGState()
        context.addRects([artboard, source])
        context.clip(using: .evenOdd)
        context.setFillColor(CGColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1))
        context.fill(artboard)
        context.restoreGState()
    }
}

final class AnnotationCanvas: NSView {
    private struct Hit: Equatable {
        let index: Int
        let handle: AnnotationHandle?
    }

    private struct Drag {
        let start: CGPoint
        var end: CGPoint
        let target: Hit?
        var penPoints: [CGPoint] = []

        var offset: CGPoint { CGPoint(x: end.x - start.x, y: end.y - start.y) }
    }

    let imageSize: CGSize
    var tool: AnnotationTool = .arrow {
        didSet {
            finishText()
            resetSelection()
            onStyleChange?()
        }
    }
    var annotations: [ImageAnnotation] = [] {
        didSet {
            needsDisplay = true
            onGeometryChange?()
            onStyleChange?()
        }
    }
    var onChange: (([ImageAnnotation]) -> Void)?
    var onStyleChange: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var onDragScroll: ((NSPoint) -> Void)?
    private var textInput: AnnotationTextInput?
    var isEditable = true { didSet { if !isEditable { resetSelection() } } }

    private var color = CGColor(srgbRed: 0.95, green: 0.16, blue: 0.22, alpha: 1)
    private var widths: [AnnotationTool: CGFloat] = [:]
    private var artboard: CGRect
    private var tracking: NSTrackingArea?
    private var hover: Hit? {
        didSet { if hover != oldValue { needsDisplay = true } }
    }
    private var selectedIndex: Int? {
        didSet {
            if selectedIndex != oldValue {
                needsDisplay = true
                onStyleChange?()
            }
        }
    }
    private var drag: Drag?
    private var selection: ImageAnnotation? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        return annotations[selectedIndex]
    }

    var styleColor: CGColor { textInput?.color ?? selection?.color ?? color }
    var styleTool: AnnotationTool { textInput != nil ? .text : selection?.tool ?? tool }
    var styleWidth: CGFloat { textInput?.fontSize ?? editingPreview?.width ?? selection?.width ?? drawingWidth }
    var widthScale: CGFloat { max(1, min(imageSize.width, imageSize.height) / 500) }
    private var drawingWidth: CGFloat {
        if let width = widths[tool] { return width }
        if tool == .text { return AnnotationFontSize.rounded(20 * widthScale) }
        return (tool == .marker ? 12 : tool.widthOptions[1]) * widthScale
    }
    var preferredResponder: NSResponder { textInput?.textView ?? self }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private(set) var scale: CGFloat = 1
    var isDragging: Bool { drag != nil }
    private var sourceBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    var contentBounds: CGRect {
        var visible = annotationsIncludingText
        if let index = drag?.target?.index, let preview = editingPreview {
            visible[index] = preview
        } else if let draft {
            visible.append(draft)
        }
        return AnnotationArtboard.bounds(for: sourceBounds, annotations: visible)
    }

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        artboard = CGRect(origin: .zero, size: imageSize)
        super.init(frame: CGRect(origin: .zero, size: imageSize))
        clipsToBounds = false
        setAccessibilityRole(.image)
        setAccessibilityLabel("Холст разметки")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layout() {
        super.layout()
        textInput?.fit(at: scale, origin: artboard.origin)
    }

    func place(frame: CGRect, artboard: CGRect, scale: CGFloat) {
        self.scale = scale
        self.artboard = artboard
        self.frame = frame
        needsLayout = true
        needsDisplay = true
    }

    func viewPoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - artboard.minX) * scale, y: (point.y - artboard.minY) * scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [
            .inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate
        ], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func cursorUpdate(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) {
        hover = nil
        if drag == nil { NSCursor.arrow.set() }
    }

    func resetSelection() {
        let cancelledDrag = isDragging
        drag = nil
        selectedIndex = nil
        hover = nil
        needsDisplay = true
        if cancelledDrag { onGeometryChange?() }
        if let window, window.isKeyWindow {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(location) { idleCursor.set() }
        }
    }

    func setStyle(color: CGColor? = nil, width: CGFloat? = nil) {
        let width = styleTool == .marker ? nil : width
        if let color { self.color = color }
        if let width { widths[styleTool] = width }
        if let textInput {
            textInput.setStyle(color: color ?? textInput.color, fontSize: width ?? textInput.fontSize)
            textInput.fit(at: scale, origin: artboard.origin)
            onGeometryChange?()
            onTextChange?()
        } else if let selectedIndex, annotations.indices.contains(selectedIndex) {
            var updated = annotations
            if let color { updated[selectedIndex].color = color }
            if let width { updated[selectedIndex].width = width }
            onChange?(updated)
        }
        onStyleChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -artboard.minX, y: -artboard.minY)
        AnnotationArtboard.drawPadding(in: context, source: sourceBounds, artboard: artboard)
        let preview = editingPreview
        let activeIndex = drag?.target?.index ?? hover?.index ?? selectedIndex
        var activeAnnotation: ImageAnnotation?
        for (index, annotation) in annotations.enumerated() {
            if index == textInput?.index { continue }
            let item = index == drag?.target?.index ? preview ?? annotation : annotation
            item.draw(in: context)
            if index == activeIndex { activeAnnotation = item }
        }
        if let draft {
            draft.draw(in: context)
        } else if drag == nil || drag?.target != nil, let activeAnnotation, isEditable {
            drawHandles(for: activeAnnotation, focused: drag?.target?.handle ?? hover?.handle, in: context)
        }
    }

    private func drawHandles(for annotation: ImageAnnotation, focused: AnnotationHandle?, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let handles = annotation.handles
        if annotation.tool.group == .freehand || annotation.tool == .text {
            context.saveGState()
            context.setLineWidth(1 / scale)
            context.setStrokeColor(accent)
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            context.stroke(annotation.bounds)
            context.restoreGState()
        }
        for (handle, point) in handles {
            let radius = (handle == focused ? 5.5 : 4) / scale
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.58).cgColor)
            context.setLineWidth(3 / scale)
            context.strokeEllipse(in: rect)
            context.setFillColor(accent)
            context.fillEllipse(in: rect)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.35 / scale)
            context.strokeEllipse(in: rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        finishText()
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)
        let target = hit(at: point)
        selectedIndex = target?.index
        hover = target
        if let target {
            if event.clickCount == 2, case .text(let value, let position) = annotations[target.index].shape {
                editText(value, at: position, index: target.index)
                return
            }
        } else if tool == .text {
            editText("", at: point, index: nil)
            return
        }
        drag = Drag(start: point, end: point, target: target,
                    penPoints: target == nil && tool.group == .freehand ? [point] : [])
        if let target { (target.handle?.cursor ?? .closedHand).set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        onDragScroll?(event.locationInWindow)
        updateDrag(with: event)
        onGeometryChange?()
        if styleTool == .text, drag?.target?.handle != nil { onStyleChange?() }
    }

    private func updateDrag(with event: NSEvent) {
        let point = imagePoint(for: event)
        drag?.end = point
        if drag?.target == nil, tool.group == .freehand, drag?.penPoints.last != point {
            drag?.penPoints.append(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture = drag else { return }
        updateDrag(with: event)
        let newAnnotation = draft
        let editedAnnotation = editingPreview
        drag = nil
        if let target = gesture.target, let editedAnnotation {
            var updated = annotations
            updated[target.index] = editedAnnotation
            onChange?(updated)
        } else if let newAnnotation {
            let index = annotations.count
            onChange?(annotations + [newAnnotation])
            if annotations.indices.contains(index) { selectedIndex = index }
        }
        needsDisplay = true
        onGeometryChange?()
        updateHover(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        finishText(commit: false)
        resetSelection()
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable, [51, 117].contains(event.keyCode),
              let selectedIndex, annotations.indices.contains(selectedIndex) else {
            super.keyDown(with: event)
            return
        }
        var updated = annotations
        updated.remove(at: selectedIndex)
        resetSelection()
        onChange?(updated)
    }

    private func editText(_ value: String, at point: CGPoint, index: Int?) {
        let input = AnnotationTextInput(value, at: point, index: index, fontSize: styleWidth, color: styleColor)
        textInput = input
        addSubview(input)
        input.fit(at: scale, origin: artboard.origin)
        input.onChange = { [weak self, weak input] in
            guard let self else { return }
            input?.fit(at: self.scale, origin: self.artboard.origin)
            self.onGeometryChange?()
            self.onTextChange?()
        }
        input.onCancel = { [weak self] in self?.cancelOperation(nil) }
        window?.makeFirstResponder(input.textView)
        input.textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        needsDisplay = true
        onStyleChange?()
    }

    var annotationsIncludingText: [ImageAnnotation] {
        guard let input = textInput else { return annotations }
        var updated = annotations
        if let index = input.index {
            if let note = input.annotation { updated[index] = note }
            else { updated.remove(at: index) }
        } else if let note = input.annotation {
            updated.append(note)
        }
        return updated
    }

    func finishText(commit: Bool = true) {
        guard let input = textInput else { return }
        if commit { input.textView.unmarkText() }
        let updated = commit ? annotationsIncludingText : annotations
        textInput = nil
        if window?.firstResponder === input.textView { window?.makeFirstResponder(self) }
        input.removeFromSuperview()
        if updated != annotations {
            selectedIndex = nil
            hover = nil
            onChange?(updated)
        }
        needsDisplay = true
        onGeometryChange?()
        onStyleChange?()
        onTextChange?()
    }

    private var idleCursor: NSCursor { isEditable ? (tool == .text ? .iBeam : .crosshair) : .arrow }

    private func updateHover(with event: NSEvent) {
        guard drag == nil else { return }
        let local = convert(event.locationInWindow, from: nil)
        if let textInput, textInput.frame.contains(local) {
            hover = nil
            NSCursor.iBeam.set()
            return
        }
        guard visibleRect.contains(local), isEditable else {
            hover = nil
            NSCursor.arrow.set()
            return
        }
        hover = hit(at: imagePoint(for: event))
        let cursor = hover.map { $0.handle?.cursor ?? .openHand } ?? idleCursor
        cursor.set()
    }

    private func hit(at point: CGPoint) -> Hit? {
        let radius = 7 / scale
        func nearestHandle(at index: Int) -> (hit: Hit, distance: CGFloat)? {
            var nearest: (hit: Hit, distance: CGFloat)?
            for (kind, anchor) in annotations[index].handles {
                let distance = hypot(anchor.x - point.x, anchor.y - point.y)
                if distance <= radius, distance < (nearest?.distance ?? .infinity) {
                    nearest = (Hit(index: index, handle: kind), distance)
                }
            }
            return nearest
        }
        if let selectedIndex, annotations.indices.contains(selectedIndex), let nearest = nearestHandle(at: selectedIndex) {
            return nearest.hit
        }
        // Handles are drawn above the strokes, including where two figures meet.
        var nearest: (hit: Hit, distance: CGFloat)?
        for index in annotations.indices.reversed() {
            if let candidate = nearestHandle(at: index), candidate.distance < (nearest?.distance ?? .infinity) {
                nearest = candidate
            }
        }
        if let nearest { return nearest.hit }
        return annotations.lastIndex { $0.hit(point, margin: 4 / scale) }.map { Hit(index: $0, handle: nil) }
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: artboard.minX + point.x / scale, y: artboard.minY + point.y / scale)
    }

    var editingPreview: ImageAnnotation? {
        guard let drag, let target = drag.target, annotations.indices.contains(target.index) else { return nil }
        let original = annotations[target.index]
        let offset = drag.offset
        if let handle = target.handle {
            return original.resized(at: handle, by: offset, minimumSize: 3 / scale)
        }
        return original.moved(by: offset)
    }

    var draft: ImageAnnotation? {
        guard let drag, drag.target == nil else { return nil }
        let start = drag.start, end = drag.end
        let dx = end.x - start.x, dy = end.y - start.y
        let shape: ImageAnnotation.Shape
        switch tool {
        case .arrow, .openArrow, .doubleArrow, .line:
            guard hypot(dx, dy) * scale >= 3 else { return nil }
            let style: ImageAnnotation.ArrowStyle = tool == .openArrow ? .open : tool == .doubleArrow ? .double : .filled
            shape = tool == .line ? .line(start, end) : .arrow(start, end, style: style)
        case .circle:
            let diameter = min(abs(dx), abs(dy))
            guard diameter * scale >= 3 else { return nil }
            let radius = diameter / 2
            shape = .circle(center: CGPoint(x: start.x + (dx < 0 ? -radius : radius),
                                            y: start.y + (dy < 0 ? -radius : radius)), radius: radius)
        case .frame:
            guard min(abs(dx), abs(dy)) * scale >= 3 else { return nil }
            shape = .frame(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(dx), height: abs(dy)))
        case .pen, .marker, .highlighter:
            guard drag.penPoints.count > 1 else { return nil }
            let style: ImageAnnotation.FreehandStyle = tool == .marker ? .marker : tool == .highlighter ? .highlighter : .pencil
            shape = .pen(drag.penPoints, style: style)
        case .text:
            return nil
        }
        return ImageAnnotation(shape: shape, color: color, width: drawingWidth)
    }
}
