// Image annotations in top-left pixel coordinates. GPL-3.0.
import AppKit

enum AnnotationTool: Int {
    case arrow, frame, pen, text, circle, line

    static let shapes: [Self] = [.frame, .circle, .line]

    var title: String {
        switch self {
        case .arrow: return "Стрелка"
        case .frame: return "Рамка"
        case .circle: return "Круг"
        case .line: return "Линия"
        case .pen: return "Перо"
        case .text: return "Текст"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .frame: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        }
    }
}

enum AnnotationHandle: Equatable {
    enum Axis: CaseIterable {
        case minimum, middle, maximum

        func position(from minimum: CGFloat, to maximum: CGFloat) -> CGFloat {
            switch self {
            case .minimum: return minimum
            case .middle: return (minimum + maximum) / 2
            case .maximum: return maximum
            }
        }

        func resized(minimum: CGFloat, maximum: CGFloat, by delta: CGFloat,
                     limit: CGFloat, minimumSize: CGFloat) -> (CGFloat, CGFloat) {
            let span = min(minimumSize, maximum - minimum)
            switch self {
            case .minimum: return (min(maximum - span, max(0, minimum + delta)), maximum)
            case .middle: return (minimum, maximum)
            case .maximum: return (minimum, max(minimum + span, min(limit, maximum + delta)))
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
    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint)
        case frame(CGRect)
        case circle(center: CGPoint, radius: CGFloat)
        case line(CGPoint, CGPoint)
        case pen([CGPoint])
        case text(String, CGPoint)
    }

    var shape: Shape
    var color: CGColor
    var width: CGFloat

    private var path: CGPath {
        let path = CGMutablePath()
        switch shape {
        case .arrow(let start, let end):
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { return path }
            let dx = (end.x - start.x) / length, dy = (end.y - start.y) / length
            let head = min(width * 3.5, length * 0.6)
            let base = CGPoint(x: end.x - dx * head, y: end.y - dy * head)
            func offset(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
                CGPoint(x: point.x - dy * distance, y: point.y + dx * distance)
            }
            let shaft = min(width / 2, head / 3)
            path.addLines(between: [offset(start, by: shaft), offset(base, by: shaft),
                offset(base, by: head / 2), end, offset(base, by: -head / 2),
                offset(base, by: -shaft), offset(start, by: -shaft)])
            path.closeSubpath()
        case .frame(let rect):
            path.addRect(rect)
        case .circle(let center, let radius):
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
        case .line(let start, let end):
            path.move(to: start)
            path.addLine(to: end)
        case .pen(let points):
            path.addLines(between: points)
        case .text:
            break
        }
        return path
    }

    var bounds: CGRect {
        if case .text(let text, let point) = shape {
            return CGRect(origin: point, size: AnnotationTextLayout(text, width: width, color: color).size)
        }
        return path.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
    }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color)
        switch shape {
        case .text(let text, let point):
            AnnotationTextLayout(text, width: width, color: color).draw(at: point, in: context)
        case .arrow:
            context.addPath(path)
            context.fillPath()
        case .frame, .circle, .line, .pen:
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setStrokeColor(color)
            context.addPath(path)
            context.strokePath()
        }
    }

    func hit(_ point: CGPoint, margin: CGFloat) -> Bool {
        if case .text = shape { return bounds.insetBy(dx: -margin, dy: -margin).contains(point) }
        let outline = path
        let reach = width / 2 + margin
        guard outline.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).contains(point) else { return false }
        if case .arrow = shape, outline.contains(point) { return true }
        return outline.copy(strokingWithWidth: width + margin * 2,
                            lineCap: .round, lineJoin: .round, miterLimit: 4).contains(point)
    }

    var handles: [(kind: AnnotationHandle, point: CGPoint)] {
        switch shape {
        case .arrow(let start, let end), .line(let start, let end):
            return [(.start, start), (.tip, end)]
        case .circle(let center, let radius):
            return [(.frame(x: .minimum, y: .middle), CGPoint(x: center.x - radius, y: center.y)),
                    (.frame(x: .maximum, y: .middle), CGPoint(x: center.x + radius, y: center.y)),
                    (.frame(x: .middle, y: .minimum), CGPoint(x: center.x, y: center.y - radius)),
                    (.frame(x: .middle, y: .maximum), CGPoint(x: center.x, y: center.y + radius))]
        case .frame(let rect):
            return AnnotationHandle.Axis.allCases.flatMap { y in
                AnnotationHandle.Axis.allCases.compactMap { x in
                    guard x != .middle || y != .middle else { return nil }
                    return (.frame(x: x, y: y), CGPoint(
                        x: x.position(from: rect.minX, to: rect.maxX),
                        y: y.position(from: rect.minY, to: rect.maxY)))
                }
            }
        case .pen, .text:
            return []
        }
    }

    func resized(at handle: AnnotationHandle, by offset: CGPoint, in imageSize: CGSize,
                 minimumSize: CGFloat) -> ImageAnnotation {
        var annotation = self
        func shift(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(imageSize.width, max(0, point.x + offset.x)),
                    y: min(imageSize.height, max(0, point.y + offset.y)))
        }
        switch (shape, handle) {
        case (.arrow(let start, let end), .start), (.arrow(let start, let end), .tip),
             (.line(let start, let end), .start), (.line(let start, let end), .tip):
            let a = handle == .start ? shift(start) : start
            let b = handle == .tip ? shift(end) : end
            if a != b {
                if case .arrow = shape { annotation.shape = .arrow(a, b) }
                else { annotation.shape = .line(a, b) }
            }
        case (.circle(let center, let radius), .frame(let x, let y)):
            let horizontal = y == .middle
            let sign: CGFloat = (horizontal ? x : y) == .maximum ? 1 : -1
            let fixed = (horizontal ? center.x : center.y) - sign * radius
            let cross = horizontal ? center.y : center.x
            let axialLimit = sign > 0 ? (horizontal ? imageSize.width : imageSize.height) - fixed : fixed
            let crossLimit = min(cross, (horizontal ? imageSize.height : imageSize.width) - cross)
            let diameter = min(axialLimit, 2 * crossLimit, max(min(minimumSize, 2 * radius),
                2 * radius + sign * (horizontal ? offset.x : offset.y)))
            let mid = fixed + sign * diameter / 2
            annotation.shape = .circle(center: horizontal ? CGPoint(x: mid, y: cross) : CGPoint(x: cross, y: mid),
                                       radius: diameter / 2)
        case (.frame(let rect), .frame(let x, let y)):
            let (left, right) = x.resized(minimum: rect.minX, maximum: rect.maxX, by: offset.x,
                                          limit: imageSize.width, minimumSize: minimumSize)
            let (top, bottom) = y.resized(minimum: rect.minY, maximum: rect.maxY, by: offset.y,
                                           limit: imageSize.height, minimumSize: minimumSize)
            annotation.shape = .frame(CGRect(x: left, y: top, width: right - left, height: bottom - top))
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
        case .arrow(let start, let end): annotation.shape = .arrow(move(start), move(end))
        case .frame(let rect): annotation.shape = .frame(rect.offsetBy(dx: offset.x, dy: offset.y))
        case .circle(let center, let radius): annotation.shape = .circle(center: move(center), radius: radius)
        case .line(let start, let end): annotation.shape = .line(move(start), move(end))
        case .pen(let points): annotation.shape = .pen(points.map(move))
        case .text(let text, let point): annotation.shape = .text(text, move(point))
        }
        return annotation
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
    var tool: AnnotationTool = .arrow { didSet { finishText(); resetSelection() } }
    var annotations: [ImageAnnotation] = [] {
        didSet {
            needsDisplay = true
            onStyleChange?()
        }
    }
    var onChange: (([ImageAnnotation]) -> Void)?
    var onStyleChange: (() -> Void)?
    var onTextChange: (() -> Void)?
    private var textInput: AnnotationTextInput?
    var isEditable = true { didSet { if !isEditable { resetSelection() } } }

    private var color = CGColor(srgbRed: 0.95, green: 0.16, blue: 0.22, alpha: 1)
    private var lineWidth: CGFloat = 4
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
    var styleWidth: CGFloat { textInput?.width ?? selection?.width ?? lineWidth }
    var preferredResponder: NSResponder { textInput?.textView ?? self }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var scale: CGFloat { max(.leastNormalMagnitude, bounds.width / imageSize.width) }

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        super.init(frame: CGRect(origin: .zero, size: imageSize))
        clipsToBounds = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Холст разметки")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layout() {
        super.layout()
        textInput?.fit(at: scale)
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
        drag = nil
        selectedIndex = nil
        hover = nil
        needsDisplay = true
        if let window, window.isKeyWindow {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(location) { idleCursor.set() }
        }
    }

    func setStyle(color: CGColor? = nil, width: CGFloat? = nil) {
        if let color { self.color = color }
        if let width { lineWidth = width }
        if let textInput {
            textInput.setStyle(color: color ?? textInput.color, width: width ?? textInput.width)
            textInput.fit(at: scale)
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
        if handles.isEmpty {
            context.setLineWidth(1 / scale)
            context.setStrokeColor(accent)
            context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
            context.stroke(annotation.bounds.insetBy(dx: -4 / scale, dy: -4 / scale))
            return
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
        drag = Drag(start: point, end: point, target: target, penPoints: target == nil && tool == .pen ? [point] : [])
        if let target { (target.handle?.cursor ?? .closedHand).set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        let point = imagePoint(for: event)
        drag?.end = point
        if drag?.target == nil, tool == .pen, drag?.penPoints.last != point {
            drag?.penPoints.append(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture = drag else { return }
        mouseDragged(with: event)
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
        let input = AnnotationTextInput(value, at: point, index: index, width: styleWidth, color: styleColor)
        textInput = input
        addSubview(input)
        input.fit(at: scale)
        input.onChange = { [weak self, weak input] in
            guard let self else { return }
            input?.fit(at: self.scale)
            self.onTextChange?()
        }
        input.onCancel = { [weak self] in self?.cancelOperation(nil) }
        window?.makeFirstResponder(input.textView)
        input.textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        needsDisplay = true
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
        return CGPoint(x: min(imageSize.width, max(0, point.x / scale)),
                       y: min(imageSize.height, max(0, point.y / scale)))
    }

    var editingPreview: ImageAnnotation? {
        guard let drag, let target = drag.target, annotations.indices.contains(target.index) else { return nil }
        let original = annotations[target.index]
        let offset = drag.offset
        if let handle = target.handle {
            return original.resized(at: handle, by: offset, in: imageSize, minimumSize: 3 / scale)
        }
        let bounds = original.bounds
        let dx = min(max(0, imageSize.width - bounds.maxX), max(min(0, -bounds.minX), offset.x))
        let dy = min(max(0, imageSize.height - bounds.maxY), max(min(0, -bounds.minY), offset.y))
        return original.moved(by: CGPoint(x: dx, y: dy))
    }

    var draft: ImageAnnotation? {
        guard let drag, drag.target == nil else { return nil }
        let start = drag.start, end = drag.end
        let dx = end.x - start.x, dy = end.y - start.y
        let shape: ImageAnnotation.Shape
        switch tool {
        case .arrow, .line:
            guard hypot(dx, dy) * scale >= 3 else { return nil }
            shape = tool == .arrow ? .arrow(start, end) : .line(start, end)
        case .circle:
            let diameter = min(abs(dx), abs(dy))
            guard diameter * scale >= 3 else { return nil }
            let radius = diameter / 2
            shape = .circle(center: CGPoint(x: start.x + (dx < 0 ? -radius : radius),
                                            y: start.y + (dy < 0 ? -radius : radius)), radius: radius)
        case .frame:
            guard min(abs(dx), abs(dy)) * scale >= 3 else { return nil }
            shape = .frame(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(dx), height: abs(dy)))
        case .pen:
            guard drag.penPoints.count > 1 else { return nil }
            shape = .pen(drag.penPoints)
        case .text:
            return nil
        }
        return ImageAnnotation(shape: shape, color: color, width: lineWidth)
    }
}
