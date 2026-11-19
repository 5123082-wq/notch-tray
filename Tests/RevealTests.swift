// Native offscreen rendering: idle must contain no visible pixels, with or
// without files. Uses its own temporary shelf and never reads the user's files.
import AppKit
import QuartzCore

@main
struct RevealTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for populated in [false, true] {
            let root = base.appendingPathComponent(populated ? "populated" : "empty")
            if populated {
                let source = base.appendingPathComponent("example.txt")
                try Data("Test file".utf8).write(to: source)
                let store = try TrayStorage(root: root)
                try store.importFile(source)
            }
            let controller = try TrayController(root: root)
            controller.panel.orderOut(nil)
            precondition(controller.geometry.closedSize.width == controller.geometry.notchWidth)
            precondition(controller.geometry.closedSize.height == controller.geometry.notchHeight)
            precondition(controller.panel.ignoresMouseEvents)
            controller.panel.setFrame(controller.geometry.frame(open: true), display: false)
            controller.view.layoutSubtreeIfNeeded()
            for progress: Double in [0, 0.5, 1, 0] {
                controller.view.present(expansion: progress)
                controller.view.displayIfNeeded()
                let width = Int(controller.view.bounds.width)
                let height = Int(controller.view.bounds.height)
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                controller.view.layer!.render(in: context)
                let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
                let visible = (0..<(width * height)).filter { pixels[$0 * 4 + 3] > 0 }.count
                if progress == 0 { precondition(visible == 0, "Idle rendered visible pixels") }
                else { precondition(visible > 0, "Expanded surface failed to render") }
                print("PASS: \(populated ? "populated" : "empty") shelf, reveal \(progress), visible pixels \(visible)")
            }
            controller.panel.close()
        }
        print("Native reveal checks passed.")
    }
}
