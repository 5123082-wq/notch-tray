// These tests inject every system effect. They never post keys, activate apps,
// read the real foreground app, or display a macOS permission prompt.
import AppKit

private final class ShortcutHarness {
    let target = ShortcutTarget(processIdentifier: 10, launchDate: Date(timeIntervalSince1970: 100), name: "Finder")
    let other = ShortcutTarget(processIdentifier: 20, launchDate: Date(timeIntervalSince1970: 200), name: "Other")
    let tray = ShortcutTarget(processIdentifier: 99, launchDate: Date(timeIntervalSince1970: 300), name: "Notch Tray")
    var frontmost: ShortcutTarget?
    var running: [pid_t: ShortcutTarget] = [:]
    var allowed = true
    var activationSucceeds = true
    var postSucceeds = true
    var activations: [pid_t] = []
    var posted: [pid_t] = []
    var permissionRequests = 0
    var onPermissionCheck: (() -> Void)?
    var scheduled: [() -> Void] = []

    init() {
        frontmost = target
        for app in [target, other, tray] { running[app.processIdentifier] = app }
    }

    func service() -> ShortcutActionService {
        ShortcutActionService(environment: ShortcutActionEnvironment(
            ownPID: tray.processIdentifier,
            frontmost: { self.frontmost },
            isRunning: { target in self.running[target.processIdentifier]?.isSameProcess(as: target) == true },
            activate: { target in self.activations.append(target.processIdentifier); return self.activationSucceeds },
            hasPermission: {
                self.onPermissionCheck?()
                return self.allowed
            },
            requestPermission: { self.permissionRequests += 1 },
            postToSession: {
                self.posted.append(self.frontmost?.processIdentifier ?? 0)
                return self.postSucceeds
            },
            schedule: { _, action in self.scheduled.append(action) }
        ), observeActivations: false)
    }

    func tick() { if !scheduled.isEmpty { scheduled.removeFirst()() } }
    func drain() {
        for _ in 0..<30 where !scheduled.isEmpty { tick() }
        precondition(scheduled.isEmpty, "Focus wait must be bounded")
    }
}

@main
struct ShortcutActionTests {
    static func failure<T>(_ result: Result<T, ShortcutActionError>?, _ expected: ShortcutActionError) {
        guard case .failure(let error)? = result, error == expected else {
            preconditionFailure("Expected \(expected), received \(String(describing: result))")
        }
    }

    static func main() throws {
        var checks = 0
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            precondition(h.posted.isEmpty && result == nil, "Click must finish before posting")
            h.drain()
            try result!.get()
            precondition(h.posted == [h.target.processIdentifier] && h.activations.isEmpty)
            precondition(h.permissionRequests == 0)
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            h.allowed = false
            failure(service.prepareGoToFolder(), .accessibilityPermissionRequired)
            precondition(h.permissionRequests == 0 && h.posted.isEmpty && h.activations.isEmpty)
            service.requestPermission()
            precondition(h.permissionRequests == 1 && h.posted.isEmpty)
            checks += 1
        }
        do {
            let h = ShortcutHarness()
            h.frontmost = h.tray
            failure(h.service().prepareGoToFolder(), .noTarget)
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            h.frontmost = h.tray
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            precondition(h.activations == [h.target.processIdentifier])
            h.tick()
            precondition(h.posted.isEmpty && result == nil, "Activation request is not completed activation")
            h.frontmost = h.target
            h.drain()
            try result!.get()
            precondition(h.posted == [h.target.processIdentifier])
            checks += 1
        }
        for switchBeforeSend in [false, true] {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            if switchBeforeSend { h.frontmost = h.other }
            service.send(action) { result = $0 }
            if !switchBeforeSend { h.frontmost = h.other }
            h.drain()
            failure(result, .targetChanged)
            precondition(h.posted.isEmpty && h.activations.isEmpty, "Do not steal focus or redirect a stale action")
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.onPermissionCheck = { [unowned h] in h.frontmost = h.other }
            h.drain()
            failure(result, .targetChanged)
            precondition(h.posted.isEmpty, "Check focus after the permission check before posting to the session")
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.running.removeValue(forKey: h.target.processIdentifier)
            h.drain()
            failure(result, .targetUnavailable)
            precondition(h.posted.isEmpty)
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.running[h.target.processIdentifier] = ShortcutTarget(processIdentifier: h.target.processIdentifier,
                launchDate: Date(timeIntervalSince1970: 999), name: "Reused PID")
            h.drain()
            failure(result, .targetUnavailable)
            precondition(h.posted.isEmpty, "A reused PID must not receive the action")
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.allowed = false
            h.drain()
            failure(result, .accessibilityPermissionRequired)
            precondition(h.posted.isEmpty && h.permissionRequests == 0)
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            h.frontmost = h.tray
            let action = try service.prepareGoToFolder().get()
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.drain()
            failure(result, .activationFailed)
            precondition(h.posted.isEmpty && h.activations.count == 1)
            checks += 1
        }
        do {
            let h = ShortcutHarness(), service = h.service()
            let action = try service.prepareGoToFolder().get()
            h.postSucceeds = false
            var result: Result<Void, ShortcutActionError>?
            service.send(action) { result = $0 }
            h.drain()
            failure(result, .eventCreationFailed)
            checks += 1
        }
        do {
            let events = ShortcutActionService.makeGoToFolderEvents()!
            precondition(events.count == 2 && events[0].type == .keyDown && events[1].type == .keyUp)
            for event in events {
                precondition(event.getIntegerValueField(.keyboardEventKeycode) == 5)
                precondition(event.flags == [.maskCommand, .maskShift], "Send only Command–Shift–G")
            }
            checks += 1
        }
        print("Shortcut action checks passed: \(checks); no real events or permission prompts.")
    }
}
