// Controls shared by the groups in the annotation toolbar. GPL-3.0.
import AppKit

final class AnnotationToolbarGroup: NSStackView {
    init(controls: [NSView], spacing: CGFloat = 2) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        self.spacing = spacing
        edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        controls.forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        plate.fill()
        NSColor.labelColor.withAlphaComponent(0.09).setStroke()
        plate.stroke()
    }
}

final class AnnotationToolbarButton: NSButton {
    enum Mark {
        case swatch(CGColor)
        case stroke(CGFloat)
    }

    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    private let mark: Mark?
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            setAccessibilityValue(NSNumber(value: selected))
            needsDisplay = true
        }
    }

    init(title: String, help: String, symbol: String? = nil, mark: Mark? = nil,
         width: CGFloat, isChoice: Bool = false) {
        self.mark = mark
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 12, weight: .medium)
        isBordered = false
        setButtonType(.momentaryChange)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        toolTip = help
        setAccessibilityLabel(help)
        if isChoice {
            setAccessibilityRole(.radioButton)
            setAccessibilityValue(NSNumber(value: false))
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHighlighted || hovered || selected {
            let fill = selected
                ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.32 : 0.20)
                : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.17 : 0.08)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            fill.setFill()
            shape.fill()
        }
        guard let mark else {
            super.draw(dirtyRect)
            return
        }
        switch mark {
        case .swatch(let color):
            let swatch = NSBezierPath(ovalIn: CGRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12))
            (NSColor(cgColor: color) ?? .controlAccentColor).withAlphaComponent(isEnabled ? 1 : 0.42).setFill()
            swatch.fill()
            NSColor.labelColor.withAlphaComponent(0.20).setStroke()
            swatch.stroke()
            if selected, isEnabled {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: swatch.bounds.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        case .stroke(let width):
            let line = NSBezierPath()
            line.move(to: CGPoint(x: bounds.midX - 5, y: bounds.midY))
            line.line(to: CGPoint(x: bounds.midX + 5, y: bounds.midY))
            line.lineWidth = width
            line.lineCapStyle = .round
            (isEnabled ? NSColor.labelColor : .disabledControlTextColor).setStroke()
            line.stroke()
        }
    }
}

final class AnnotationToolbarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.minY, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 1)).fill()
    }
}
