// Manual integration fixture for Notch Tray's external-app shortcuts.
// Compile this file alone into a separate .app, launch, then click the shelf's
// Cmd-Shift-G button while either native sheet is open. It never saves files.
import AppKit

private final class ShortcutTargetDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var picker: NSSavePanel?
    private var eventMonitor: Any?
    private var shortcutCount = 0
    private let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchTray-ShortcutTarget-\(UUID().uuidString)", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
            try Data("Notch Tray shortcut fixture\n".utf8).write(to: fixtureDirectory.appendingPathComponent("example.txt"))
        } catch {
            print("FIXTURE_ERROR: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 190),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notch Tray Shortcut Test"
        window.isReleasedWhenClosed = false
        let description = NSTextField(wrappingLabelWithString:
            "Open a native file dialog, then click ⌘⇧G on the shelf. The path entry should appear in that dialog. Save only closes the test dialog; no file is written.")
        description.frame = NSRect(x: 20, y: 108, width: 520, height: 58)
        window.contentView?.addSubview(description)
        let openButton = NSButton(title: "Test Open Dialog", target: self, action: #selector(showOpen))
        openButton.frame = NSRect(x: 20, y: 61, width: 230, height: 32)
        openButton.bezelStyle = .rounded
        openButton.setAccessibilityIdentifier("test-open-dialog")
        window.contentView?.addSubview(openButton)
        let saveButton = NSButton(title: "Test Save Dialog", target: self, action: #selector(showSave))
        saveButton.frame = NSRect(x: 270, y: 61, width: 230, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.setAccessibilityIdentifier("test-save-dialog")
        window.contentView?.addSubview(saveButton)
        status = NSTextField(labelWithString: "No shortcut received yet")
        status.frame = NSRect(x: 20, y: 21, width: 520, height: 22)
        window.contentView?.addSubview(status)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 5, modifiers.contains([.command, .shift]),
               !modifiers.contains(.option), !modifiers.contains(.control), let self {
                self.shortcutCount += 1
                self.status.stringValue = "Received ⌘⇧G \(self.shortcutCount) time(s)"
                print("SHORTCUT_RECEIVED count=\(self.shortcutCount) dialog=\(self.picker is NSOpenPanel ? "open" : self.picker == nil ? "none" : "save")")
                fflush(stdout)
            }
            return event
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("FIXTURE_READY pid=\(ProcessInfo.processInfo.processIdentifier) directory=\(fixtureDirectory.path)")
        fflush(stdout)
        if CommandLine.arguments.contains("--open") { showOpen() }
        if CommandLine.arguments.contains("--save") { showSave() }
    }

    @objc private func showOpen() {
        guard picker == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Shortcut Test — Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        present(panel)
    }

    @objc private func showSave() {
        guard picker == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Shortcut Test — Save"
        panel.nameFieldStringValue = "never-written.txt"
        panel.canCreateDirectories = false
        present(panel)
    }

    private func present(_ panel: NSSavePanel) {
        picker = panel
        panel.directoryURL = fixtureDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.picker = nil
            print("DIALOG_CLOSED response=\(response.rawValue); no file was read or saved")
            fflush(stdout)
        }
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Shortcut Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        for (title, action, key) in [("Open Test Dialog", #selector(showOpen), "o"),
                                     ("Save Test Dialog", #selector(showSave), "s")] {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }
}

@main
private struct ShortcutTarget {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ShortcutTargetDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
