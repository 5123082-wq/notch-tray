// Notch Tray — GPL-3.0.
import Foundation

struct ScreenshotSettings: Codable, Equatable {
    var automaticImport = true
    var removeAfterDrag = true
    var customFolderPath: String?
    var folderBookmark: Data?

    func resolvedFolder() -> URL {
        if customFolderPath != nil, let data = folderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        if let path = customFolderPath { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return ScreenshotFolder.systemFolder()
    }
}

/// Owned by the controller on main. Pass value snapshots to the monitor queue.
final class ScreenshotSettingsStore {
    private let url: URL
    private(set) var settings: ScreenshotSettings

    init(root: URL) throws {
        url = root.appendingPathComponent("screenshot-settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            settings = try JSONDecoder().decode(ScreenshotSettings.self, from: Data(contentsOf: url))
        } else { settings = ScreenshotSettings() }
    }

    func save(_ newSettings: ScreenshotSettings) throws {
        var updated = newSettings
        if updated.customFolderPath != settings.customFolderPath || (updated.customFolderPath != nil && updated.folderBookmark == nil) {
            updated.folderBookmark = updated.customFolderPath.flatMap { path in
                try? URL(fileURLWithPath: path, isDirectory: true).bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
        if updated.customFolderPath == nil { updated.folderBookmark = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: url, options: .atomic)
        settings = updated
    }
}

enum ScreenshotFolder {
    private static let domain = "com.apple.screencapture" as CFString

    private static func preference(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? String
    }

    /// These preferences are best-effort discovery, not a public macOS contract.
    /// A user-selected folder always takes priority over this fallback.
    static func systemFolder() -> URL {
        CFPreferencesAppSynchronize(domain)
        for key in ["location-screenshot", "location"] {
            if let value = preference(key), !value.isEmpty {
                if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL { return url.standardizedFileURL }
                let path = (value as NSString).expandingTildeInPath
                if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func systemTargetIssue() -> String? {
        CFPreferencesAppSynchronize(domain)
        let target = preference("target-screenshot") ?? preference("target")
        guard let target, !["file", "disk"].contains(target) else { return nil }
        return "macOS сейчас сохраняет снимки не в папку. Для приёма файлов выберите папку через ⇧⌘5 → Параметры."
    }
}
