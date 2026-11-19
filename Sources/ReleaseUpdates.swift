// Offer published releases from the project's GitHub repository. GPL-3.0.
import AppKit

struct PublishedRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    func newerVersion(than current: String) throws -> String? {
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        func components(_ value: String) throws -> [Int] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...4).contains(parts.count) else { throw URLError(.cannotParseResponse) }
            return try parts.map { part in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(part)
                else { throw URLError(.cannotParseResponse) }
                return n
            } + Array(repeating: 0, count: 4 - parts.count)
        }
        guard !draft, !prerelease else { return nil }
        return try components(current).lexicographicallyPrecedes(components(version)) ? version : nil
    }
}

final class ReleaseUpdates: NSObject {
    private static let latest = URL(string: "https://api.github.com/repos/5123082-wq/notch-tray/releases/latest")!
    private static let downloads = URL(string: "https://github.com/5123082-wq/notch-tray/releases/latest")!
    private let session = URLSession(configuration: .ephemeral)
    private let defaults = UserDefaults.standard
    private let interval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?
    private var checking = false
    private var requestedByUser = false
    private(set) var availableVersion: String?
    var onChange: (() -> Void)?

    var automatic: Bool { defaults.object(forKey: "checkPublishedReleases") as? Bool ?? true }

    func start() {
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        guard automatic else { return }
        let last = defaults.object(forKey: "lastReleaseCheck") as? Date ?? .distantPast
        let delay = min(interval, max(1, interval + last.timeIntervalSinceNow))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        timer.fireDate = Date(timeIntervalSinceNow: delay)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func toggleAutomatic() {
        defaults.set(!automatic, forKey: "checkPublishedReleases")
        schedule()
        onChange?()
    }

    @objc func manualCheck() {
        if availableVersion != nil { openRelease(); return }
        requestedByUser = true
        check()
    }

    private func openRelease() { NSWorkspace.shared.open(Self.downloads) }

    private func check() {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: Self.latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, _ in
            let result: Result<String?, Error> = Result {
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                else { throw URLError(.badServerResponse) }
                return try JSONDecoder().decode(PublishedRelease.self, from: data).newerVersion(than: current)
            }
            DispatchQueue.main.async { self?.finish(result) }
        }.resume()
    }

    private func finish(_ result: Result<String?, Error>) {
        checking = false
        let manual = requestedByUser
        requestedByUser = false
        if case .success(let version) = result {
            availableVersion = version
            defaults.set(Date(), forKey: "lastReleaseCheck")
            onChange?()
        }
        guard manual else { return }
        let alert = NSAlert()
        switch result {
        case .success(.some(let version)):
            alert.messageText = "Доступна версия " + version
            alert.addButton(withTitle: "Открыть выпуск")
            alert.addButton(withTitle: "Позже")
        case .success(nil): alert.messageText = "У вас актуальная версия Notch Tray"
        case .failure:
            alert.messageText = "Не удалось проверить обновления"
            alert.informativeText = "Попробуйте ещё раз позже."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, case .success(.some) = result { openRelease() }
    }

    deinit { timer?.invalidate(); session.invalidateAndCancel() }
}
