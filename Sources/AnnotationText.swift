// Shared TextKit layout for typing, hit testing and full-resolution export. GPL-3.0.
import AppKit

final class AnnotationTextLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude))

    static func font(for width: CGFloat) -> NSFont { .boldSystemFont(ofSize: max(15, width * 5)) }

    static func attributes(width: CGFloat, color: CGColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        return [.font: font(for: width),
                .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: paragraph]
    }

    init(_ string: String, width: CGFloat, color: CGColor) {
        storage = NSTextStorage(string: string, attributes: Self.attributes(width: width, color: color))
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
    private(set) var width: CGFloat
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }

    init(_ value: String, at anchor: CGPoint, index: Int?, width: CGFloat, color: CGColor) {
        self.anchor = anchor
        self.index = index
        self.color = color
        self.width = width
        textLayout = AnnotationTextLayout(value, width: width, color: color)
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
        setStyle(color: color, width: width)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setStyle(color: CGColor, width: CGFloat) {
        self.color = color
        self.width = width
        let attributes = AnnotationTextLayout.attributes(width: width, color: color)
        textLayout.storage.setAttributes(attributes, range: NSRange(location: 0, length: textLayout.storage.length))
        textView.typingAttributes = attributes
        textView.insertionPointColor = NSColor(cgColor: color) ?? .textColor
    }

    func fit(at scale: CGFloat) {
        let used = textLayout.size
        let lineHeight = textLayout.manager.defaultLineHeight(for: AnnotationTextLayout.font(for: width))
        let size = CGSize(width: max(4, used.width + 3), height: max(used.height, lineHeight))
        // TextKit always lays out image pixels. Scale the containing view as a unit.
        frame = CGRect(x: anchor.x * scale, y: anchor.y * scale, width: size.width * scale, height: size.height * scale)
        bounds = CGRect(origin: .zero, size: size)
        textView.frame = bounds
    }

    var annotation: ImageAnnotation? {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ImageAnnotation(shape: .text(text, anchor), color: color, width: width)
    }

    func textDidChange(_ notification: Notification) { onChange?() }

    func undoManager(for view: NSTextView) -> UndoManager? { typingHistory }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel?()
        return true
    }
}
