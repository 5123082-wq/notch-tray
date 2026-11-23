// Canvas gestures, PNG export and shelf publication, using isolated fixtures.
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageEditingTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("Image editing checks passed."); exit(0) }
            catch { fputs("Image editing failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor
    static func run() async throws {
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = output.appendingPathComponent("image-edit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func check(_ label: String, _ condition: @autoclosure () throws -> Bool) throws {
            guard try condition() else { throw NSError(domain: "ImageEditingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            print("PASS: \(label)")
        }
        func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(label, predicate())
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<80 { for x in 0..<120 {
            let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
            let blue = x < 10 && y < 10
            pixel[0] = blue ? 0 : 255
            pixel[1] = blue ? 0 : 255
            pixel[2] = 255
            pixel[3] = x > 100 && y > 60 ? 0 : 255
        }}
        let png = bitmap.representation(using: .png, properties: [:])!
        let original = base.appendingPathComponent("Снимок.png")
        try png.write(to: original)
        let source = try EditableImage(url: original)
        try check("Source retains full pixel dimensions", source.image.width == 120 && source.image.height == 80)
        let blank = NSBitmapImageRep(data: try source.png(annotations: []))!
        try check("Unmarked export preserves the top-left image orientation", blank.colorAt(x: 3, y: 3)!.blueComponent > 0.9 && blank.colorAt(x: 3, y: 3)!.redComponent < 0.1)
        try check("PNG export preserves transparent pixels", blank.colorAt(x: 110, y: 70)!.alphaComponent < 0.01)
        let arrow = ImageAnnotation(shape: .arrow(CGPoint(x: 20, y: 20), CGPoint(x: 85, y: 20)),
                                    color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), width: 5)
        let editedPNG = try source.png(annotations: [arrow])
        let rendered = NSBitmapImageRep(data: editedPNG)!
        try check("The renderer exports the arrow at the correct top-left canvas coordinates",
            rendered.colorAt(x: 40, y: 20)!.redComponent > 0.9 && rendered.colorAt(x: 40, y: 20)!.greenComponent < 0.15 &&
            rendered.colorAt(x: 40, y: 60)!.greenComponent > 0.9)
        try check("Markup export retains full resolution and alpha", rendered.pixelsWide == 120 && rendered.pixelsHigh == 80 && rendered.colorAt(x: 110, y: 70)!.alphaComponent < 0.01)
        try editedPNG.write(to: output.appendingPathComponent("annotation-arrow-export.png"))
        let text = ImageAnnotation(shape: .text("Снимок", CGPoint(x: 15, y: 30)), color: arrow.color, width: 20)
        let pen = ImageAnnotation(shape: .pen([CGPoint(x: 72, y: 59), CGPoint(x: 64, y: 61), CGPoint(x: 53, y: 59)]),
                                  color: arrow.color, width: 4)
        let notes = NSBitmapImageRep(data: try source.png(annotations: [text, pen]))!
        try check("Text and pen strokes are included in the full-resolution export",
            (30..<54).contains { y in (15..<75).contains { x in notes.colorAt(x: x, y: y)!.greenComponent < 0.6 } } &&
                notes.colorAt(x: 64, y: 61)!.greenComponent < 0.1)

        let overflow = ImageAnnotation(shape: .line(CGPoint(x: -10, y: -8), CGPoint(x: 130, y: 90)),
                                       color: arrow.color, width: 4)
        let expandedBounds = AnnotationArtboard.bounds(for: source.bounds, annotations: [overflow])
        let expanded = NSBitmapImageRep(data: try source.png(annotations: [overflow]))!
        let margin = expanded.colorAt(x: 0, y: expanded.pixelsHigh - 1)!.usingColorSpace(.sRGB)!
        try check("Export grows in all directions to the stroke bounds",
            expandedBounds == CGRect(x: -12, y: -10, width: 144, height: 102) &&
            expanded.pixelsWide == 144 && expanded.pixelsHigh == 102)
        try check("Expanded export keeps the source aligned and paints only the margins",
            abs(margin.redComponent - 230.0 / 255) < 0.02 && abs(margin.greenComponent - margin.redComponent) < 0.02 &&
            expanded.colorAt(x: 14, y: 18)!.redComponent < 0.1 && expanded.colorAt(x: 14, y: 18)!.blueComponent > 0.9 &&
            expanded.colorAt(x: 122, y: 80)!.alphaComponent < 0.01)
        let outsideLabel = ImageAnnotation(shape: .text("Строка", CGPoint(x: 115, y: 78)), color: arrow.color, width: 20)
        let labelBounds = AnnotationArtboard.bounds(for: source.bounds, annotations: [outsideLabel])
        try check("Text participates in canvas growth along its right and bottom edges",
            labelBounds.maxX > 120 && labelBounds.maxY > 80)
        let tooWide = overflow.moved(by: CGPoint(x: 80_000_000, y: 0))
        do {
            _ = try source.png(annotations: [tooWide])
            throw ImageEditError.renderFailed
        } catch ImageEditError.tooLarge {
            try check("Oversized artboards are rejected before allocating a bitmap", true)
        }
        let flatStroke = ImageAnnotation(shape: .pen([CGPoint(x: 5, y: 9), CGPoint(x: 35, y: 9)]),
                                        color: arrow.color, width: 4)
        let widerFlatStroke = flatStroke.resized(at: .frame(x: .maximum, y: .maximum),
                                               by: CGPoint(x: 15, y: 7), minimumSize: 3)
        try check("Resizing an exactly horizontal stroke stretches its usable axis without introducing invalid geometry",
            widerFlatStroke.shape == .pen([CGPoint(x: 5, y: 9), CGPoint(x: 50, y: 9)]) &&
            widerFlatStroke.handles.count == 8 && widerFlatStroke.width == flatStroke.width)
        let highlight = ImageAnnotation(shape: .pen([CGPoint(x: 28, y: 24), CGPoint(x: 90, y: 24)], style: .highlighter),
                                        color: arrow.color, width: 18)
        let highlighted = NSBitmapImageRep(data: try source.png(annotations: [highlight]))!
        try check("Highlighter leaves the base visible through its stroke",
            (0.50...0.74).contains(highlighted.colorAt(x: 45, y: 24)!.greenComponent))

        let jpeg = NSMutableData()
        let jpgDestination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(jpgDestination, bitmap.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(jpgDestination))
        let rotatedURL = base.appendingPathComponent("Rotated.jpg")
        try (jpeg as Data).write(to: rotatedURL)
        let rotated = try EditableImage(url: rotatedURL)
        try check("EXIF orientation is applied without downsampling", rotated.image.width == 80 && rotated.image.height == 120)
        let invalid = base.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: invalid)
        try check("Invalid images do not offer editing", !EditableImage.supports(invalid))
        let animated = base.appendingPathComponent("animation.gif")
        let gif = CGImageDestinationCreateWithURL(animated as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(gif, bitmap.cgImage!, nil)
        CGImageDestinationAddImage(gif, bitmap.cgImage!, nil)
        precondition(CGImageDestinationFinalize(gif))
        try check("Animated images are not flattened silently", !EditableImage.supports(animated))

        let root = base.appendingPathComponent("shelf")
        let storage = try TrayStorage(root: root)
        let originalID = ScreenshotFile.inspect(original)!.sourceID
        let entry = try storage.importScreenshot(original, sourceID: originalID)!
        let oldURL = storage.url(for: entry)
        let updated = try storage.saveEditedImage(editedPNG, for: entry.id, expectedRevision: nil)
        try check("Saving keeps the same card, category, date, and original path", updated.id == entry.id && updated.category == entry.category && updated.added == entry.added && updated.screenshotSourcePath == original.path && storage.items.count == 1)
        try check("The new URL serves the edited PNG", try Data(contentsOf: storage.url(for: updated)) == editedPNG)
        try check("Save replaces the external original and preserves previously handed-out bytes", try Data(contentsOf: original) == editedPNG && Data(contentsOf: oldURL) == png)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shelf.json"))) as! [String: Any]
        try check("Completed screenshot saves keep the v3 manifest and release the journal", document["version"] as? Int == 3 && document["pendingScreenshotEdits"] == nil)
        let restarted = try TrayStorage(root: root)
        let updatedID = ScreenshotFile.inspect(original)!.sourceID
        try check("Restart restores the revision and both source identities", restarted.items == storage.items && updated.screenshotSourceID == updatedID && restarted.processedScreenshotSources.isSuperset(of: [originalID, updatedID]))
        try check("Edited screenshots are not imported again", try restarted.importScreenshot(original, sourceID: updatedID) == nil)
        do { _ = try storage.saveEditedImage(editedPNG, for: entry.id, expectedRevision: nil); fatalError("stale edit accepted") }
        catch { try check("A stale editor cannot overwrite a newer revision", storage.items == [updated]) }

        // A failing manifest write must not publish the new revision or damage the last save.
        let manifest = root.appendingPathComponent("shelf.json")
        let savedManifest = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: true)
        do { _ = try storage.saveEditedImage(png, for: entry.id, expectedRevision: updated.imageRevision); fatalError("failed write accepted") }
        catch {
            try check("A write failure preserves the last saved revision", storage.items == [updated] && (try Data(contentsOf: storage.url(for: updated))) == editedPNG)
            try check("A write failure preserves the external version", try Data(contentsOf: original) == editedPNG)
            let revisions = try fm.contentsOfDirectory(atPath: storage.url(for: updated).deletingLastPathComponent().deletingLastPathComponent().path)
            try check("A failed save removes its incomplete revision", revisions.count == 1)
        }
        try fm.removeItem(at: manifest)
        try savedManifest.write(to: manifest)

        let controller = try TrayController(root: root)
        var settings = ScreenshotSettings()
        settings.customFolderPath = base.path
        try controller.saveScreenshotSettings(settings)
        defer { controller.panel.closePreview(); controller.panel.orderOut(nil) }
        controller.switchSection(.screenshots)
        controller.view.finishSectionTransition()
        controller.showPinned()
        controller.selectOnly(entry.id)
        controller.previewSelection()
        let preview = controller.panel.imagePreview!
        NSApp.activate(ignoringOtherApps: true)
        preview.makeKeyAndOrderFront(nil)
        try await wait("The image preview receives keyboard focus") { preview.isKeyWindow }
        preview.ignoresMouseEvents = true
        try check("Quick Look offers the native editing entry point", preview.editButton.title == "Редактировать" && preview.previewView.previewItem.previewItemURL == controller.url(for: updated))
        preview.editButton.performClick(nil)
        try await wait("The Edit button opens the built-in editor") { controller.imageEditors[entry.id] != nil }
        let editor = controller.imageEditors[entry.id]!
        defer { editor.window?.orderOut(nil) }
        try await wait("The editor is ready for native actions") { editor.window?.isKeyWindow == true }
        try await wait("Editing closes Quick Look and collapses the shelf completely") {
            !preview.isVisible && !controller.panel.isPreviewing && !controller.isExpanded && !controller.isPinned &&
                controller.geometry.frame(open: false).insetBy(dx: -1, dy: -1).contains(controller.panel.frame)
        }
        editor.window?.ignoresMouseEvents = true
        let trigger = controller.geometry.trigger
        controller.dragObserver.onHover?(NSPoint(x: trigger.midX, y: trigger.midY))
        controller.dragObserver.onMouseDown?(NSPoint(x: trigger.midX, y: trigger.midY))
        controller.armExternalDrag()
        try check("Hover and dragging cannot reopen the shelf over the editor", !controller.isExpanded && !controller.isPinned && !controller.externalDragActive)
        func ignorePhysicalPointerEvents(_ controller: TrayController) {
            controller.dragObserver.onHover = nil
            controller.dragObserver.onMouseDown = nil
            controller.dragObserver.onMove = nil
            controller.dragObserver.onRelease = nil
        }
        ignorePhysicalPointerEvents(controller)
        func pointer(_ type: NSEvent.EventType, in canvas: AnnotationCanvas, at point: CGPoint, clicks: Int = 1) {
            let location = canvas.convert(canvas.viewPoint(for: point), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1)!
            switch type {
            case .mouseMoved: canvas.mouseMoved(with: event)
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: preconditionFailure("Unexpected pointer event")
            }
        }
        func drawArrow(in editor: ImageEditor) {
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            editor.canvas.tool = .arrow
            pointer(.leftMouseDown, in: editor.canvas, at: CGPoint(x: 83, y: 57))
            pointer(.leftMouseDragged, in: editor.canvas, at: CGPoint(x: 36, y: 48))
            pointer(.leftMouseUp, in: editor.canvas, at: CGPoint(x: 25, y: 45))
        }
        let canvas = editor.canvas
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        try check("The editor opens with a visible canvas and Arrow selected",
            canvas.window === editor.window && canvas.frame.width > 0 && canvas.tool == .arrow)
        try check("A new editor starts clean", !editor.hasChanges && !editor.saveButton.isEnabled)
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let editorContent = editor.window!.contentView!
        func visibleButtons() -> [AnnotationToolbarButton] {
            descendants(of: editorContent).compactMap { $0 as? AnnotationToolbarButton }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        func button(_ title: String) -> AnnotationToolbarButton {
            editorContent.layoutSubtreeIfNeeded()
            return visibleButtons().first { $0.toolTip == title }!
        }
        let arrowButton = button("Стрелки")
        let textButton = button("Текст")
        let blueButton = button("Синий")
        let shapesButton = button("Фигуры")
        let freehandButton = button("Линии от руки")
        let zoom = descendants(of: editorContent).compactMap { $0 as? NSPopUpButton }.first!
        func chooseShape(_ tool: AnnotationTool) {
            shapesButton.performClick(nil)
            button(tool.title).performClick(nil)
        }
        func drag(from: CGPoint, to: CGPoint) {
            pointer(.mouseMoved, in: canvas, at: from)
            pointer(.leftMouseDown, in: canvas, at: from)
            pointer(.leftMouseDragged, in: canvas, at: to)
            pointer(.leftMouseUp, in: canvas, at: to)
        }
        func setZoom(_ index: Int) {
            zoom.selectItem(at: index)
            zoom.sendAction(zoom.action!, to: zoom.target)
            editorContent.layoutSubtreeIfNeeded()
        }
        shapesButton.performClick(nil)
        editorContent.layoutSubtreeIfNeeded()
        try check("The lower row offers frame, circle and straight line",
            AnnotationTool.Group.shapes.tools.allSatisfy { tool in visibleButtons().contains { $0.title == tool.title } })
        chooseShape(.circle)
        drag(from: CGPoint(x: 87, y: 65), to: CGPoint(x: 29, y: 25))
        guard let circle = canvas.annotations.first else { throw ImageEditError.renderFailed }
        try check("A non-square reverse drag creates a true circle with four handles",
            circle.shape == .circle(center: CGPoint(x: 67, y: 45), radius: 20) && circle.handles.count == 4)
        drag(from: CGPoint(x: 87, y: 45), to: CGPoint(x: 97, y: 46))
        try check("Dragging a circle handle preserves its proportions", canvas.annotations.first?.shape ==
            .circle(center: CGPoint(x: 72, y: 45), radius: 25))
        chooseShape(.line)
        drag(from: CGPoint(x: 72, y: 45), to: CGPoint(x: 24, y: 45))
        guard let line = canvas.annotations.last else { throw ImageEditError.renderFailed }
        try check("The circle interior is free for drawing a horizontal line",
            canvas.annotations.count == 2 && line.shape == .line(CGPoint(x: 72, y: 45), CGPoint(x: 24, y: 45)))
        drag(from: CGPoint(x: 24, y: 45), to: CGPoint(x: 24, y: 38))
        try check("A line endpoint moves independently", canvas.annotations.last?.shape ==
            .line(CGPoint(x: 72, y: 45), CGPoint(x: 24, y: 38)))
        let shapesPNG = NSBitmapImageRep(data: try source.png(annotations: [circle, line]))!
        try check("Export strokes the circle and line, leaving the circle interior clear",
            shapesPNG.colorAt(x: 67, y: 25)!.greenComponent < 0.35 &&
            shapesPNG.colorAt(x: 70, y: 45)!.greenComponent < 0.35 &&
            shapesPNG.colorAt(x: 67, y: 34)!.greenComponent > 0.9)
        for _ in 0..<4 { editor.undo(nil) }
        try check("Shape gestures undo independently", !editor.hasChanges)

        arrowButton.performClick(nil)
        for (tool, style) in [(AnnotationTool.openArrow, ImageAnnotation.ArrowStyle.open), (.doubleArrow, .double)] {
            button(tool.title).performClick(nil)
            drag(from: CGPoint(x: 18, y: 22), to: CGPoint(x: 76, y: 38))
            try check("\(tool.title) is drawn as a separate arrow style with two editable endpoints",
                canvas.annotations.last?.shape == .arrow(CGPoint(x: 18, y: 22), CGPoint(x: 76, y: 38), style: style) &&
                canvas.annotations.last?.handles.count == 2)
            editor.undo(nil)
        }
        freehandButton.performClick(nil)
        arrowButton.performClick(nil)
        try check("Returning to Arrows remembers the last variant", canvas.tool == .doubleArrow)
        button(AnnotationTool.arrow.title).performClick(nil)

        for tool in AnnotationTool.Group.freehand.tools {
            freehandButton.performClick(nil)
            button(tool.title).performClick(nil)
            editorContent.layoutSubtreeIfNeeded()
            try check("\(tool.title) exposes the correct width controls",
                visibleButtons().contains { $0.toolTip == "Тонкая линия" } == (tool != .marker))
            let start = CGPoint(x: 18, y: 24)
            let bend = CGPoint(x: 44, y: 48)
            let end = CGPoint(x: 78, y: 25)
            pointer(.leftMouseDown, in: canvas, at: start)
            pointer(.leftMouseDragged, in: canvas, at: bend)
            pointer(.leftMouseUp, in: canvas, at: end)
            guard let stroke = canvas.annotations.last, stroke.handles.count == 8,
                  let right = stroke.handles.first(where: { $0.kind == .frame(x: .maximum, y: .middle) })?.point else {
                throw ImageEditError.renderFailed
            }
            try check("\(tool.title) draws and gets eight resize handles", stroke.tool == tool)
            // Locate a point on the stroke away from handles, including for the widest tool.
            let shaft = CGPoint(x: 31, y: 36)
            drag(from: shaft, to: CGPoint(x: 35, y: 39))
            guard let shifted = canvas.annotations.last else { throw ImageEditError.renderFailed }
            try check("\(tool.title) moves as a single stroke", shifted == stroke.moved(by: CGPoint(x: 4, y: 3)))
            editor.undo(nil)
            drag(from: right, to: CGPoint(x: right.x + 15, y: right.y + 3))
            guard let stretched = canvas.annotations.last else { throw ImageEditError.renderFailed }
            try check("\(tool.title) stretches horizontally and keeps its width and vertical bounds",
                stretched.bounds.width > stroke.bounds.width + 10 && stretched.width == stroke.width &&
                abs(stretched.bounds.height - stroke.bounds.height) < 0.001)
            editor.undo(nil)
            editor.redo(nil)
            try check("\(tool.title) redo restores its resize", canvas.annotations == [stretched])
            editor.undo(nil)
            editor.undo(nil)
        }
        try check("Freehand drawing and resizing leave the editor clean after undo", !editor.hasChanges)

        for (zoomIndex, end) in [(0, CGPoint(x: -20, y: -12)), (3, CGPoint(x: 138, y: 96))] {
            setZoom(zoomIndex)
            arrowButton.performClick(nil)
            let start = CGPoint(x: 64, y: 42)
            let before = canvas.convert(canvas.viewPoint(for: start), to: nil)
            let oldScale = canvas.scale
            pointer(.leftMouseDown, in: canvas, at: start)
            pointer(.leftMouseDragged, in: canvas, at: end)
            let after = canvas.convert(canvas.viewPoint(for: start), to: nil)
            try check("Live growth at zoom \(zoomIndex) preserves the image anchor and the scale",
                canvas.scale == oldScale && hypot(before.x - after.x, before.y - after.y) < 1 &&
                canvas.contentBounds != source.bounds && !editor.hasChanges)
            pointer(.leftMouseUp, in: canvas, at: end)
            let exported = NSBitmapImageRep(data: try source.png(annotations: canvas.annotations))!
            try check("Expanded export agrees with the editor at zoom \(zoomIndex)",
                exported.pixelsWide == Int(canvas.contentBounds.width) &&
                exported.pixelsHigh == Int(canvas.contentBounds.height) && canvas.annotations.count == 1)
            editor.undo(nil)
            try check("Undo shrinks the expanded artboard back to the screenshot", canvas.contentBounds == source.bounds)
        }
        setZoom(0)
        let anchor = CGPoint(x: 8, y: 2)
        textButton.performClick(nil)
        pointer(.leftMouseDown, in: canvas, at: anchor)
        guard let input = editor.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        try check("Clicking Text places the native caret on the image",
            input.isDescendant(of: canvas) && input.convert(.zero as CGPoint, to: canvas) == anchor &&
            editor.window!.attachedSheet == nil && !editor.hasChanges)
        func pressReturn(in input: NSTextView) {
            input.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        }
        input.insertText("Абвгд", replacementRange: input.selectedRange())
        pressReturn(in: input)
        pressReturn(in: input)
        input.insertText("Б", replacementRange: input.selectedRange())
        try check("Return inserts newlines at the caret and enables Save while typing",
            input.string == "Абвгд\n\nБ" && editor.window!.firstResponder === input && editor.saveButton.isEnabled)
        let typedSize = AnnotationTextLayout(input.string, fontSize: canvas.styleWidth, color: canvas.styleColor).size
        try check("The multiline input fits its visible text, including space for the caret",
            typedSize.width > 45 && input.bounds.width == typedSize.width + 3 && input.bounds.height == typedSize.height)
        setZoom(3)
        try check("Zoom scales the active text at the same image coordinates",
            canvas.scale == 2 && input.convert(.zero as CGPoint, to: canvas) == CGPoint(x: 16, y: 4) &&
            editor.window!.firstResponder === input)
        setZoom(0)
        arrowButton.performClick(nil)
        guard let typed = canvas.annotations.first else { throw ImageEditError.renderFailed }
        try check("Switching tools commits one multiline label", canvas.annotations.count == 1 &&
            typed.shape == .text("Абвгд\n\nБ", anchor))
        let textPNG = NSBitmapImageRep(data: try source.png(annotations: [typed]))!
        func hasInk(_ rows: Range<Int>) -> Bool {
            rows.contains { y in (8..<27).contains { x in textPNG.colorAt(x: x, y: y)!.greenComponent < 0.4 &&
                textPNG.colorAt(x: x, y: y)!.redComponent > 0.8 } }
        }
        try check("Export and hit testing include the third line and preserve the blank line",
            hasInk(3..<24) && !hasInk(26..<47) && hasInk(52..<76) && typed.hit(CGPoint(x: 13, y: 60), margin: 0))
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 13, y: 60), clicks: 2)
        guard let reopenedText = editor.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        reopenedText.insertText("!", replacementRange: reopenedText.selectedRange())
        reopenedText.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try check("Escape cancels re-editing and restores the original label",
            canvas.annotations == [typed] && editor.window!.firstResponder === canvas)
        editor.undo(nil)
        try check("One annotation undo removes the complete multiline label", !editor.hasChanges && canvas.annotations.isEmpty)

        textButton.performClick(nil)
        editorContent.layoutSubtreeIfNeeded()
        guard let fontSize = descendants(of: editorContent).compactMap({ $0 as? NSComboBox }).first else {
            throw ImageEditError.renderFailed
        }
        try check("Text offers an editable size field and several presets in the lower toolbar",
            fontSize.isEditable && fontSize.stringValue == "20" && fontSize.numberOfItems > 3 &&
            !fontSize.isHiddenOrHasHiddenAncestor && !visibleButtons().contains { $0.toolTip == "Тонкая линия" })
        let labelAnchor = CGPoint(x: 25, y: 9)
        let label = "АБ\nВ"
        pointer(.leftMouseDown, in: canvas, at: labelAnchor)
        guard let liveText = editor.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        liveText.insertText(label, replacementRange: liveText.selectedRange())
        fontSize.selectItem(withObjectValue: "24")
        try check("Selecting a preset updates the active paragraph at 24 image pixels",
            liveText.font?.pointSize == 24 && canvas.annotationsIncludingText.last?.width == 24)
        func enterFontSize(_ value: String) throws {
            guard editor.window!.makeFirstResponder(fontSize),
                  let field = fontSize.currentEditor() as? NSTextView else { throw ImageEditError.renderFailed }
            field.insertText(value, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
            pressReturn(in: field)
        }
        try enterFontSize("27")
        try check("Typing a custom size applies it without ending the active text edit",
            editor.window!.firstResponder === liveText && liveText.font?.pointSize == 27 &&
            canvas.annotationsIncludingText.last?.width == 27 && fontSize.stringValue == "27")
        try enterFontSize("900")
        try check("An out-of-range entry restores the current valid size",
            editor.window!.firstResponder === liveText && liveText.font?.pointSize == 27 && fontSize.stringValue == "27")
        arrowButton.performClick(nil)
        guard let originalLabel = canvas.annotations.last else { throw ImageEditError.renderFailed }
        try check("The annotation retains its exact font size and eight handles",
            originalLabel.shape == .text(label, labelAnchor) && originalLabel.width == 27 && originalLabel.handles.count == 8)
        let bottomRight = CGPoint(x: originalLabel.bounds.maxX, y: originalLabel.bounds.maxY)
        let resizeTarget = CGPoint(x: bottomRight.x + originalLabel.bounds.width * 0.52,
                                   y: bottomRight.y + originalLabel.bounds.height * 0.52)
        pointer(.leftMouseDown, in: canvas, at: bottomRight)
        pointer(.leftMouseDragged, in: canvas, at: resizeTarget)
        guard let previewLabel = canvas.editingPreview else { throw ImageEditError.renderFailed }
        try check("A corner handle previews proportional text enlargement and updates the size field",
            previewLabel.width == 41 && previewLabel.shape == .text(label, labelAnchor) &&
            fontSize.stringValue == "41" && canvas.annotations == [originalLabel])
        pointer(.leftMouseUp, in: canvas, at: resizeTarget)
        try check("Releasing a text handle commits the preview and grows the artboard when needed",
            canvas.annotations == [previewLabel] && canvas.contentBounds.maxY > source.bounds.maxY)
        editor.undo(nil)
        try check("One undo restores the prior font size and artboard", canvas.annotations == [originalLabel] &&
            canvas.contentBounds == source.bounds)
        editor.redo(nil)
        let leftEdge = CGPoint(x: previewLabel.bounds.minX, y: previewLabel.bounds.midY)
        drag(from: leftEdge, to: CGPoint(x: leftEdge.x + previewLabel.bounds.width / 4, y: leftEdge.y + 7))
        guard let smaller = canvas.annotations.last else { throw ImageEditError.renderFailed }
        try check("A side handle shrinks glyphs uniformly and anchors the opposing midpoint",
            smaller.width == 31 && smaller.bounds.maxX == previewLabel.bounds.maxX &&
            smaller.bounds.midY == previewLabel.bounds.midY)
        for _ in 0..<3 { editor.undo(nil) }
        try check("Undoing both sizes and the text creation returns to a clean document", !editor.hasChanges)
        textButton.performClick(nil)
        try enterFontSize("20")

        textButton.performClick(nil)
        pointer(.leftMouseDown, in: canvas, at: anchor)
        guard let firstLabel = editor.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        firstLabel.insertText("А", replacementRange: firstLabel.selectedRange())
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 70, y: 42))
        try check("A click elsewhere commits the label and opens a new caret",
            canvas.annotations.first?.shape == .text("А", anchor) && editor.window!.firstResponder is NSTextView &&
            editor.window!.firstResponder !== firstLabel)
        arrowButton.performClick(nil)
        editor.undo(nil)
        try check("Leaving an empty caret adds no annotation or undo step", !editor.hasChanges && canvas.annotations.isEmpty)
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 60, y: 38))
        pointer(.leftMouseUp, in: canvas, at: CGPoint(x: 60, y: 38))
        try check("Clicking without a drag does not insert a shape", !editor.hasChanges && canvas.annotations.isEmpty)
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 83, y: 57))
        pointer(.leftMouseDragged, in: canvas, at: CGPoint(x: 36, y: 48))
        try check("The dragged arrow appears before release without committing a change",
            canvas.draft?.shape == .arrow(CGPoint(x: 83, y: 57), CGPoint(x: 36, y: 48)) && !editor.hasChanges)
        pointer(.leftMouseUp, in: canvas, at: CGPoint(x: 25, y: 45))
        try check("The arrow tip uses the final release point",
            canvas.annotations.first?.shape == .arrow(CGPoint(x: 83, y: 57), CGPoint(x: 25, y: 45)) &&
                editor.hasChanges && editor.saveButton.isEnabled && canvas.draft == nil)

        canvas.tool = .frame
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 106, y: 63))
        pointer(.leftMouseDragged, in: canvas, at: CGPoint(x: 91, y: 34))
        pointer(.leftMouseUp, in: canvas, at: CGPoint(x: 89, y: 32))
        try check("An upward-left drag makes a frame between both corners",
            canvas.annotations.last?.shape == .frame(CGRect(x: 89, y: 32, width: 17, height: 31)))
        try check("Undo routes through the editor's responder chain", NSApp.sendAction(Selector(("undo:")), to: nil, from: nil))
        try check("One undo removes only the frame", canvas.annotations.count == 1 && editor.hasChanges)
        try check("A second undo restores the clean state",
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) && canvas.annotations.isEmpty && !editor.hasChanges)
        try check("Redo routes through the editor's responder chain", NSApp.sendAction(Selector(("redo:")), to: nil, from: nil))
        try check("Redo restores the arrow", canvas.annotations.count == 1)
        try check("Redo restores the frame",
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) && canvas.annotations.count == 2)

        editor.window!.setContentSize(editor.window!.contentMinSize)
        editorContent.layoutSubtreeIfNeeded()
        for group in [arrowButton, shapesButton, freehandButton, textButton] {
            group.performClick(nil)
            editorContent.layoutSubtreeIfNeeded()
            let controls: [NSView] = visibleButtons()
            try check("\(group.title) remains usable at the minimum window size",
                editorContent.bounds.width <= 801 && (controls + [zoom, editor.saveButton]).allSatisfy {
                    editorContent.bounds.insetBy(dx: -1, dy: -1)
                        .contains($0.convert($0.bounds, to: editorContent)) && !$0.visibleRect.isEmpty
                })
        }
        chooseShape(.frame)
        try check("The toolbar selects Frame and keeps the selected state visible",
            button("Рамка").selected && !arrowButton.selected && canvas.tool == .frame)
        let initialAnnotations = canvas.annotations
        let tipNear = CGPoint(x: 24, y: 44)
        let tipRelease = CGPoint(x: 19, y: 39)
        pointer(.mouseMoved, in: canvas, at: tipNear)
        pointer(.leftMouseDown, in: canvas, at: tipNear)
        pointer(.leftMouseDragged, in: canvas, at: tipRelease)
        let adjustedArrow: ImageAnnotation.Shape = .arrow(CGPoint(x: 83, y: 57), CGPoint(x: 20, y: 40))
        try check("An arrow tip previews under the Frame tool without snapping or committing early",
            canvas.editingPreview?.shape == adjustedArrow && canvas.draft == nil && canvas.annotations == initialAnnotations)
        pointer(.leftMouseUp, in: canvas, at: tipRelease)
        try check("Releasing the tip commits one edit while preserving the other endpoint",
            canvas.annotations[0].shape == adjustedArrow && canvas.tool == .frame)
        editor.undo(nil)
        try check("One undo restores the arrow's previous tip", canvas.annotations == initialAnnotations)
        editor.redo(nil)

        drag(from: CGPoint(x: 83, y: 57), to: CGPoint(x: 77, y: 63))
        try check("The tail moves independently of the tip",
            canvas.annotations[0].shape == .arrow(CGPoint(x: 77, y: 63), CGPoint(x: 20, y: 40)))
        drag(from: CGPoint(x: 50, y: 52), to: CGPoint(x: 54, y: 57))
        try check("Dragging the arrow shaft moves both endpoints together",
            canvas.annotations[0].shape == .arrow(CGPoint(x: 81, y: 68), CGPoint(x: 24, y: 45)))
        try check("A frame has a control point on each corner and side", canvas.annotations[1].handles.count == 8)

        arrowButton.performClick(nil)
        drag(from: CGPoint(x: 106, y: 47.5), to: CGPoint(x: 115, y: 51.5))
        try check("A side midpoint changes only the width under the Arrow tool",
            canvas.annotations[1].shape == .frame(CGRect(x: 89, y: 32, width: 26, height: 31)))
        drag(from: CGPoint(x: 102, y: 32), to: CGPoint(x: 103, y: 23))
        try check("A top midpoint changes only the height",
            canvas.annotations[1].shape == .frame(CGRect(x: 89, y: 23, width: 26, height: 40)))
        drag(from: CGPoint(x: 89, y: 23), to: CGPoint(x: 85, y: 27))
        try check("A corner adjusts both axes and holds the opposite corner still",
            canvas.annotations[1].shape == .frame(CGRect(x: 85, y: 27, width: 30, height: 36)))
        drag(from: CGPoint(x: 115, y: 36), to: CGPoint(x: 113, y: 40))
        try check("The frame contour moves the whole frame with its dimensions intact",
            canvas.annotations[1].shape == .frame(CGRect(x: 83, y: 31, width: 30, height: 36)))
        pointer(.leftMouseDown, in: canvas, at: CGPoint(x: 113, y: 67))
        pointer(.leftMouseDragged, in: canvas, at: CGPoint(x: 106, y: 62))
        let beforeCancel = canvas.annotations
        try check("Dragging a frame corner previews the new outline",
            canvas.editingPreview?.shape == .frame(CGRect(x: 83, y: 31, width: 23, height: 31)))
        canvas.cancelOperation(nil)
        pointer(.leftMouseUp, in: canvas, at: CGPoint(x: 106, y: 62))
        try check("Escape discards a resize in progress", canvas.annotations == beforeCancel && canvas.editingPreview == nil)

        drag(from: CGPoint(x: 98, y: 49), to: CGPoint(x: 99, y: 57))
        try check("Empty space inside a frame still draws with the active tool",
            canvas.annotations.count == 3 && canvas.annotations[2].shape == .arrow(CGPoint(x: 98, y: 49), CGPoint(x: 99, y: 57)))
        blueButton.performClick(nil)
        try check("The color swatch updates only the selected annotation",
            blueButton.selected && Array(canvas.annotations.prefix(2)) == beforeCancel &&
                canvas.annotations.last?.color != beforeCancel[0].color)
        for _ in 0..<9 { editor.undo(nil) }
        try check("Each pointer gesture or color change occupies one undo step", canvas.annotations == initialAnnotations)

        if let renderPath = ProcessInfo.processInfo.environment["NOTCH_TRAY_TOOLBAR_PREVIEW"],
           let header = descendants(of: editorContent).first(where: { $0 is AnnotationToolbarBackground }) {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                header.appearance = NSAppearance(named: appearance)
                guard let bitmap = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { continue }
                header.cacheDisplay(in: header.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: renderPath, isDirectory: true).appendingPathComponent("toolbar-\(name).png"))
            }
            header.appearance = nil
        }
        var closeCancelled = false
        editor.requestClose { closeCancelled = !$0 }
        try await wait("Closing an unsaved editor asks before losing changes") { editor.window?.attachedSheet != nil }
        editor.window!.endSheet(editor.window!.attachedSheet!, returnCode: .alertSecondButtonReturn)
        try await wait("Cancel keeps the unsaved editor open") { closeCancelled && editor.window?.attachedSheet == nil }
        try check("Cancel preserves unsaved markup with the shelf still collapsed", editor.hasChanges && editor.window?.isVisible == true && !controller.isExpanded)
        let saveHandler = editor.onSave
        textButton.performClick(nil)
        pointer(.leftMouseDown, in: canvas, at: anchor)
        guard let pending = editor.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        pending.insertText("А", replacementRange: pending.selectedRange())
        pressReturn(in: pending)
        pending.insertText("Б", replacementRange: pending.selectedRange())
        editor.onSave = { _, _, completion in completion(.failure(ImageEditError.renderFailed)) }
        editor.saveButton.performClick(nil)
        try await wait("A save error keeps the editor available for retry") { !editor.isSaving && editor.window?.attachedSheet != nil }
        try check("A save error preserves dirty markup and the previous card", editor.hasChanges && controller.entries == [updated])
        try check("Save takes the active text directly from the canvas, including both lines",
            canvas.annotations.last?.shape == .text("А\nБ", anchor))
        try check("A save error leaves only the editor visible", editor.window?.isVisible == true && !controller.isExpanded && !controller.panel.isPreviewing)
        editor.window!.endSheet(editor.window!.attachedSheet!, returnCode: .alertFirstButtonReturn)
        try await wait("The error sheet dismisses before retry") { editor.window?.attachedSheet == nil }
        try await wait("Save becomes available again after dismissing the error") { editor.saveButton.isEnabled }
        editor.onSave = saveHandler
        editor.saveButton.performClick(nil)
        try await wait("Save publishes the native edit to the same card") { !editor.isSaving && editor.revision != updated.imageRevision }
        try await wait("Successful Save closes the editor and reopens the pinned shelf") {
            editor.window?.isVisible == false && controller.imageEditors.isEmpty && controller.isExpanded &&
                controller.isPinned && controller.panel.isKeyWindow && !controller.panel.isPreviewing
        }
        let latest = controller.entries.first!
        let latestURL = controller.url(for: latest)
        try check("Selection, ordering, and card identity survive saving", controller.selection == [entry.id] && controller.entries.count == 1 && latest.id == entry.id)
        try check("The card's thumbnail and drag URL switch to the saved image", controller.view.tiles.first?.entry == latest && controller.view.tiles.first?.fileURL == latestURL)
        try await wait("The returned card is visible and selected after the reveal") {
            controller.activeSection == .screenshots && controller.view.tiles.first?.selected == true &&
                controller.view.tiles.first?.visibleRect.isEmpty == false
        }
        try check("Successful save clears the document's dirty state", !editor.hasChanges && !editor.saveButton.isEnabled && editor.window?.isDocumentEdited == false)
        try check("Saving exports real changed pixels", try Data(contentsOf: latestURL) != editedPNG)
        try check("Repeated save without edits does not create another version", !editor.isSaving)
        editor.save()
        try check("No-op save retains the published revision", editor.revision == latest.imageRevision)
        let currentPNG = try Data(contentsOf: latestURL)
        try check("The Save button publishes exactly the same bytes in the screenshots folder", try Data(contentsOf: original) == currentPNG)
        var oldEditedEntry = latest
        oldEditedEntry.screenshotSourcePath = nil
        let oldEditor = ImageEditor(entry: oldEditedEntry, source: try EditableImage(url: latestURL))
        try check("An edited card from an older release can be saved without drawing again",
                  oldEditor.saveButton.isEnabled && !oldEditor.hasChanges)
        var legacySaveFinished = false
        oldEditor.onSave = { data, revision, completion in
            if !data.isEmpty && revision == latest.imageRevision { completion(.success(latest)) }
            else { completion(.failure(ImageEditError.renderFailed)) }
        }
        oldEditor.save { legacySaveFinished = $0 }
        try await wait("An explicit legacy save completes and clears the pending action") {
            legacySaveFinished && !oldEditor.saveButton.isEnabled
        }
        let savedPixels = NSBitmapImageRep(data: currentPNG)!
        try check("The saved frame has colored edges and leaves its interior intact",
            savedPixels.colorAt(x: 89, y: 46)!.greenComponent < 0.35 &&
                savedPixels.colorAt(x: 96, y: 46)!.greenComponent > 0.9)
        let savedRestart = try TrayStorage(root: root)
        try check("The integrated save survives restart", savedRestart.items == controller.entries && (try Data(contentsOf: savedRestart.url(for: savedRestart.items[0]))) == currentPNG)
        controller.previewSelection()
        try await wait("Previewing the returned card uses the saved image") {
            controller.panel.imagePreview?.fileURL == latestURL && controller.panel.imagePreview?.isVisible == true
        }
        controller.panel.closePreview()
        // Returning after editing must select the card's own section, even if the
        // command was invoked without that section being visible.
        controller.switchSection(.files)
        controller.editImage(entry.id)
        try await wait("The card can be edited again after saving") { controller.imageEditors[entry.id] != nil }
        let reopened = controller.imageEditors[entry.id]!
        try await wait("The reopened editor receives focus") { reopened.window?.isKeyWindow == true }
        reopened.window?.ignoresMouseEvents = true
        var closed = false
        reopened.requestClose { closed = $0 }
        try await wait("Closing a clean editor restores its section and selected card") {
            closed && controller.imageEditors.isEmpty && controller.isExpanded &&
                controller.activeSection == .screenshots && controller.selection == [entry.id]
        }

        controller.editImage(entry.id)
        try await wait("An editor is available for the quit flow") { controller.imageEditors[entry.id] != nil }
        let quitting = controller.imageEditors[entry.id]!
        try await wait("The quit-flow editor receives focus") { quitting.window?.isKeyWindow == true }
        quitting.window?.ignoresMouseEvents = true
        quitting.canvas.tool = .text
        pointer(.leftMouseDown, in: quitting.canvas, at: anchor)
        guard let quitInput = quitting.window!.firstResponder as? NSTextView else { throw ImageEditError.renderFailed }
        quitInput.insertText("Черновик", replacementRange: quitInput.selectedRange())
        try await wait("The quit-flow editor has unsaved changes") { quitting.hasChanges }
        var quitAllowed: Bool?
        controller.closeEditorsForTermination { quitAllowed = $0 }
        try await wait("Quitting still asks about unsaved edits") { quitting.window?.attachedSheet != nil }
        quitting.window!.endSheet(quitting.window!.attachedSheet!, returnCode: .alertSecondButtonReturn)
        try await wait("Cancelling quit keeps the editor and collapsed shelf") {
            quitAllowed == false && quitting.window?.attachedSheet == nil && !controller.isExpanded
        }
        closed = false
        quitting.requestClose { closed = $0 }
        try await wait("Closing after cancelled quit offers the normal choices") { quitting.window?.attachedSheet != nil }
        quitting.window!.endSheet(quitting.window!.attachedSheet!, returnCode: .alertThirdButtonReturn)
        try await wait("Discarding after cancelled quit restores the unchanged card") {
            closed && controller.imageEditors.isEmpty && controller.isExpanded && controller.entries == [latest]
        }
        controller.editImage(entry.id)
        try await wait("A clean editor is available for successful quit") { controller.imageEditors[entry.id] != nil }
        let clean = controller.imageEditors[entry.id]!
        try await wait("The clean editor receives focus") { clean.window?.isKeyWindow == true }
        clean.window?.ignoresMouseEvents = true
        controller.closeEditorsForTermination { quitAllowed = $0 }
        try await wait("Successful quit closes editors without reopening the shelf") {
            quitAllowed == true && controller.imageEditors.isEmpty && !controller.isExpanded
        }

        // Retired revisions remain readable for receivers, then clean up together.
        try savedRestart.remove(ids: [entry.id], now: Date(timeIntervalSinceNow: -10))
        try savedRestart.collectRetired()
        try check("Removing a card retains every handed-out version for 24 hours", fm.fileExists(atPath: oldURL.path) && fm.fileExists(atPath: latestURL.path))
        do { _ = try savedRestart.saveEditedImage(png, for: entry.id, expectedRevision: latest.imageRevision); fatalError("removed card restored by saving") }
        catch { try check("Saving never resurrects a removed screenshot", savedRestart.items.isEmpty) }
        try savedRestart.collectRetired(now: Date(timeIntervalSinceNow: 86_401))
        try check("Retired cleanup removes all revisions together", !fm.fileExists(atPath: oldURL.path) && !fm.fileExists(atPath: latestURL.path))
        try check("Cleanup preserves the edited external file and every retired source identity", try Data(contentsOf: original) == currentPNG && savedRestart.processedScreenshotSources.isSuperset(of: [originalID, updatedID, ScreenshotFile.inspect(original)!.sourceID]))

        // A returned card may be below the visible row after other files arrived.
        let crowdedRoot = base.appendingPathComponent("crowded-shelf")
        let crowdedStorage = try TrayStorage(root: crowdedRoot)
        for _ in 0..<16 { _ = try crowdedStorage.importFile(original) }
        let target = crowdedStorage.items.last!
        let crowded = try TrayController(root: crowdedRoot)
        ignorePhysicalPointerEvents(crowded)
        defer { crowded.panel.orderOut(nil) }
        crowded.showPinned()
        crowded.selectOnly(target.id)
        crowded.view.layoutSubtreeIfNeeded()
        try check("The crowded fixture starts with the target below the visible row",
            crowded.view.tiles.last!.frame.minY > crowded.view.scroll.contentView.bounds.maxY)
        crowded.editImage(target.id)
        try await wait("An offscreen card opens its editor") { crowded.imageEditors[target.id] != nil }
        let offscreenEditor = crowded.imageEditors[target.id]!
        defer { offscreenEditor.window?.orderOut(nil) }
        try await wait("The offscreen card's editor receives focus") { offscreenEditor.window?.isKeyWindow == true }
        offscreenEditor.window?.ignoresMouseEvents = true
        drawArrow(in: offscreenEditor)
        try await wait("The offscreen card has an edit to save") { offscreenEditor.hasChanges }
        offscreenEditor.saveDocument(nil)
        try await wait("Saving scrolls the reopened shelf to the updated card") {
            crowded.imageEditors.isEmpty && crowded.isExpanded && crowded.view.tiles.last!.visibleRect.height > 100
        }
        try check("Returning preserves a card's position in a crowded shelf",
            crowded.entries.map(\.id) == crowdedStorage.items.map(\.id) && crowded.selection == [target.id] &&
                crowded.view.tiles.last?.entry.imageRevision != nil)
    }
}
