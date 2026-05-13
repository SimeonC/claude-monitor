import Cocoa
import ClaudeMonitorCore

/// Lightweight AppKit shim. NSWorkspace notifications must be observed on .main; this shim
/// receives them there and immediately hops to engine.queue — zero parsing on the main thread.
struct ActiveAppToken {
    let bundleId: String
    let pid: pid_t
}

final class WorkspaceActivationShim {
    private var observer: Any?

    init(engine: WatcherEngine) {
        let terminalBundleIds = Set(terminalProviders.map(\.bundleIdentifier))

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak engine] notification in
            guard
                let app = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleId = app.bundleIdentifier
            else { return }
            let token = ActiveAppToken(bundleId: bundleId, pid: app.processIdentifier)
            engine?.ingestActiveAppToken(token)
        }
    }

    deinit {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }
}
