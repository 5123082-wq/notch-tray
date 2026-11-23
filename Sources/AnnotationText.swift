// Shared TextKit layout for typing, hit testing and full-resolution export. GPL-3.0.
import AppKit

enum AnnotationFontSize {
    static let range = 6...512
    static let presets = [12, 16, 20, 24, 28, 36, 48, 64, 96, 128]

    static func rounded(_ size: CGFloat) -> CGFloat {
        min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), size.rounded()))
    }
}

final class AnnotationTextLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude))

    static func font(for fontSize: CGFloat) -> NSFont { .boldSystemFont(ofSize: fontSize) }

    static func attributes(fontSize: CGFloat, color: CGColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        return [.font: font(for: fontSize),
                .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: paragraph]
    }

    init(_ string: String, fontSize: CGFloat, color: CGColor) {
        storage = NSTextStorage(string: string, attributes: Self.attributes(fontSize: fontSize, color: color))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        // Export also uses this layout on a worker thread.
        manager.backgroundLayoutEnabled = false
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
    }

    var size: CGSize {
        let glyphs = manager.glyphRange(for: container)
        var size = CGSize.zero
        // During typing, usedRect(for:) can include the entire container after Return.
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            size.width = max(size.width, used.maxX)
            size.height = max(size.height, used.maxY)
        }
        if manager.extraLineFragmentTextContainer != nil {
            let font = storage.length > 0 ? storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont : nil
            size.height += font.map(manager.defaultLineHeight(for:)) ?? manager.extraLineFragmentRect.height
        }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    func draw(at point: CGPoint, in context: CGContext) {
        let glyphs = manager.glyphRange(for: container)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        manager.drawGlyphs(forGlyphRange: glyphs, at: point)
    }
}

final class AnnotationTextInput: NSView, NSTextViewDelegate {
    let anchor: CGPoint
    let index: Int?
    let textView: NSTextView
    private let textLayout: AnnotationTextLayout
    private let typingHistory = UndoManager()
    private(set) var color: CGColor
    private(set) var fontSize: CGFloat
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }

    init(_ value: String, at anchor: CGPoint, index: Int?, fontSize: CGFloat, color: CGColor) {
        self.anchor = anchor
        self.index = index
        self.color = color
        self.fontSize = fontSize
        textLayout = AnnotationTextLayout(value, fontSize: fontSize, color: color)
        textView = NSTextView(frame: .zero, textContainer: textLayout.container)
        super.init(frame: .zero)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.allowsUndo = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel("Текст разметки")
        textView.delegate = self
        setStyle(color: color, fontSize: fontSize)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setStyle(color: CGColor, fontSize: CGFloat) {
        self.color = color
        self.fontSize = fontSize
        let attributes = AnnotationTextLayout.attributes(fontSize: fontSize, color: color)
        textLayout.storage.setAttributes(attributes, range: NSRange(location: 0, length: textLayout.storage.length))
        textView.typingAttributes = attributes
        textView.insertionPointColor = NSColor(cgColor: color) ?? .textColor
    }

    func fit(at scale: CGFloat, origin: CGPoint) {
        let used = textLayout.size
        let lineHeight = textLayout.manager.defaultLineHeight(for: AnnotationTextLayout.font(for: fontSize))
        let size = CGSize(width: max(4, used.width + 3), height: max(used.height, lineHeight))
        // TextKit always lays out image pixels. Scale the containing view as a unit.
        frame = CGRect(x: (anchor.x - origin.x) * scale, y: (anchor.y - origin.y) * scale,
                       width: size.width * scale, height: size.height * scale)
        bounds = CGRect(origin: .zero, size: size)
        textView.frame = bounds
    }

    var annotation: ImageAnnotation? {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ImageAnnotation(shape: .text(text, anchor), color: color, width: fontSize)
    }

    func textDidChange(_ notification: Notification) { onChange?() }

    func undoManager(for view: NSTextView) -> UndoManager? { typingHistory }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel?()
        return true
    }
}
