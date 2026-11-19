// Notch Tray, a standalone tray-only derivative. GPL-3.0.
import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    var tray: TrayController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Run under the app's LaunchServices identity, before loading any user data.
        if let index = CommandLine.arguments.firstIndex(of: "--permission-report"),
           CommandLine.arguments.indices.contains(index + 1) {
            let report: [String: Any] = [
                "bundlePath": Bundle.main.bundlePath,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "accessibility": AXIsProcessTrusted(),
                "postEvents": CGPreflightPostEventAccess()
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            } catch { NSLog("Permission report failed: %@", error.localizedDescription) }
            NSApp.terminate(nil)
            return
        }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let show = NSMenuItem(title: "Открыть полку", action: #selector(showShelf), keyEquivalent: "")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Notch Tray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        // Re-opening a local build must not create two competing notch panels.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 {
            NSApp.terminate(nil)
            return
        }
        let override = ProcessInfo.processInfo.environment["NOTCH_TRAY_DATA_DIR"]
        let root = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchTray", isDirectory: true)
        do {
            tray = try TrayController(root: root, monitorScreenshots: true)
            if override == nil { tray?.startReleaseChecks() }
            if CommandLine.arguments.contains("--show") { tray?.showPinned() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Не удалось открыть Notch Tray"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if (tray?.busy ?? 0) > 0 { return .terminateCancel }
        if let tray, !tray.imageEditors.isEmpty {
            DispatchQueue.main.async {
                tray.closeEditorsForTermination { sender.reply(toApplicationShouldTerminate: $0) }
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func showShelf() { tray?.showPinned() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        tray?.expand()
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
