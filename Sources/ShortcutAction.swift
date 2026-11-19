// Notch Tray — GPL-3.0. 2026-11-09.
import AppKit
import ApplicationServices

enum ShortcutActionError: Error, LocalizedError, Equatable {
    case accessibilityPermissionRequired
    case noTarget
    case targetUnavailable
    case targetChanged
    case activationFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Разрешите Notch Tray управлять компьютером в настройках универсального доступа, затем вернитесь в нужное окно и нажмите кнопку ещё раз."
        case .noTarget:
            return "Сначала откройте Finder или окно открытия / сохранения файла в другом приложении."
        case .targetUnavailable:
            return "Приложение было закрыто. Откройте нужное окно и нажмите кнопку ещё раз."
        case .targetChanged:
            return "Активное приложение изменилось. Вернитесь в нужное окно и нажмите кнопку ещё раз."
        case .activationFailed:
            return "Не удалось вернуть фокус приложению. Выберите нужное окно и нажмите кнопку ещё раз."
        case .eventCreationFailed:
            return "Не удалось отправить сочетание клавиш. Попробуйте ещё раз."
        }
    }
}

// A launch date distinguishes a relaunched application that reused the same PID.
struct ShortcutTarget {
    let processIdentifier: pid_t
    let launchDate: Date?
    let name: String

    func isSameProcess(as other: ShortcutTarget) -> Bool {
        processIdentifier == other.processIdentifier && launchDate == other.launchDate
    }

    init(processIdentifier: pid_t, launchDate: Date?, name: String) {
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
        self.name = name
    }

    init?(_ application: NSRunningApplication?) {
        guard let application, !application.isTerminated,
              application.activationPolicy != .prohibited else { return nil }
        self.init(processIdentifier: application.processIdentifier,
                  launchDate: application.launchDate,
                  name: application.localizedName ?? "приложение")
    }
}

struct PreparedShortcut {
    fileprivate let target: ShortcutTarget
    var targetName: String { target.name }
}

// Injection keeps regression tests away from the user's apps and TCC prompts.
struct ShortcutActionEnvironment {
    var ownPID: pid_t
    var frontmost: () -> ShortcutTarget?
    var isRunning: (ShortcutTarget) -> Bool
    var activate: (ShortcutTarget) -> Bool
    var hasPermission: () -> Bool
    var requestPermission: () -> Void
    var post: (ShortcutTarget) -> Bool
    var schedule: (TimeInterval, @escaping () -> Void) -> Void

    static var live: ShortcutActionEnvironment {
        ShortcutActionEnvironment(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            frontmost: { ShortcutTarget(NSWorkspace.shared.frontmostApplication) },
            isRunning: { target in
                guard let running = ShortcutTarget(NSRunningApplication(processIdentifier: target.processIdentifier)) else { return false }
                return target.isSameProcess(as: running)
            },
            activate: { target in
                // An activation request is asynchronous; send() waits for focus.
                NSRunningApplication(processIdentifier: target.processIdentifier)?.activate(options: []) ?? false
            },
            hasPermission: { CGPreflightPostEventAccess() },
            requestPermission: {
                // Request the same capability that hasPermission checks.
                _ = CGRequestPostEventAccess()
            },
            post: { target in
                guard let events = ShortcutActionService.makeGoToFolderEvents() else { return false }
                // Never post globally: a focus change must not redirect the keys.
                for event in events { event.postToPid(target.processIdentifier) }
                return true
            },
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            }
        )
    }
}

final class ShortcutActionService {
    static let goToFolderTitle = "Перейти к папке…"
    static let goToFolderSymbol = "folder"
    static let goToFolderKeys = "⌘⇧G"

    private let environment: ShortcutActionEnvironment
    private var lastExternalApplication: ShortcutTarget?
    private var activationObserver: NSObjectProtocol?

    init(environment: ShortcutActionEnvironment = .live, observeActivations: Bool = true) {
        self.environment = environment
        remember(environment.frontmost())
        if observeActivations {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.remember(ShortcutTarget(application))
            }
        }
    }

    private func remember(_ target: ShortcutTarget?) {
        guard let target, target.processIdentifier != environment.ownPID else { return }
        lastExternalApplication = target
    }

    func prepareGoToFolder() -> Result<PreparedShortcut, ShortcutActionError> {
        // Capture the app before any permission UI can activate System Settings.
        remember(environment.frontmost())
        guard let target = lastExternalApplication else { return .failure(.noTarget) }
        guard environment.isRunning(target) else { return .failure(.targetUnavailable) }
        guard environment.hasPermission() else { return .failure(.accessibilityPermissionRequired) }
        return .success(PreparedShortcut(target: target))
    }

    func requestPermission() {
        // Granting permission never replays a stale action into another window.
        environment.requestPermission()
    }

    // Call after ordering the tray panel out, so a nonactivating key panel can
    // release keyboard focus even while the target app already looks frontmost.
    func send(_ prepared: PreparedShortcut, completion: @escaping (Result<Void, ShortcutActionError>) -> Void) {
        let target = prepared.target
        guard environment.isRunning(target) else { completion(.failure(.targetUnavailable)); return }
        guard environment.hasPermission() else { completion(.failure(.accessibilityPermissionRequired)); return }
        let frontmost = environment.frontmost()
        if let frontmost, frontmost.processIdentifier != environment.ownPID,
           !frontmost.isSameProcess(as: target) {
            completion(.failure(.targetChanged))
            return
        }
        if frontmost?.processIdentifier == environment.ownPID {
            guard environment.activate(target) else { completion(.failure(.activationFailed)); return }
        }
        // Let AppKit finish the click, dismiss the tray, and return key focus.
        environment.schedule(0.08) { [weak self] in
            self?.sendWhenFocused(target, remainingAttempts: 12, completion: completion)
        }
    }

    private func sendWhenFocused(_ target: ShortcutTarget, remainingAttempts: Int,
                                 completion: @escaping (Result<Void, ShortcutActionError>) -> Void) {
        guard environment.isRunning(target) else { completion(.failure(.targetUnavailable)); return }
        let frontmost = environment.frontmost()
        if frontmost?.isSameProcess(as: target) == true {
            guard environment.hasPermission() else { completion(.failure(.accessibilityPermissionRequired)); return }
            completion(environment.post(target) ? .success(()) : .failure(.eventCreationFailed))
        } else if let frontmost, frontmost.processIdentifier != environment.ownPID {
            completion(.failure(.targetChanged))
        } else if remainingAttempts > 0 {
            environment.schedule(0.05) { [weak self] in
                self?.sendWhenFocused(target, remainingAttempts: remainingAttempts - 1, completion: completion)
            }
        } else {
            completion(.failure(.activationFailed))
        }
    }

    static func makeGoToFolderEvents() -> [CGEvent]? {
        // Private state avoids inheriting Option/Control from a physical click.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: false) else { return nil }
        for event in [down, up] { event.flags = [.maskCommand, .maskShift] }
        return [down, up]
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}
