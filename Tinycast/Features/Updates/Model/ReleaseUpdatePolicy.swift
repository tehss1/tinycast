import Foundation

enum ReleaseUpdatePolicy {
    static let notificationName = "com.tinycast.app.release-published"

    static func accepts(
        repository: String, channel: ReleaseChannel, bundlePath: String, enabled: Bool,
        inFlight: Bool, now: Date, lastAttempt: Date?
    ) -> Bool {
        repository == "tehss1/tinycast" && channel == .stable
            && bundlePath == "/Applications/Tinycast.app" && enabled && !inFlight
            && (lastAttempt.map { now.timeIntervalSince($0) >= 60 } ?? true)
    }

    static func canInstall(
        running: AppVersion?, candidate: AppVersion?, activity: UpdateActivity,
        quickActionBusy: Bool, hasVisibleWindows: Bool
    ) -> Bool {
        guard let running, let candidate, candidate > running else { return false }
        return UpdateReadiness.evaluate(activity) == nil && !quickActionBusy && !hasVisibleWindows
    }
}

struct UpdateInstallationState {
    private(set) var installedVersion: AppVersion?

    var readyToRelaunch: Bool { installedVersion != nil }

    mutating func didReplace(_ version: AppVersion) {
        installedVersion = version
    }

    var needsInstallation: Bool {
        !readyToRelaunch
    }
}

@MainActor
enum UpdateManualOwnership {
    static func takeOver(from pending: Task<Void, Never>?) async {
        pending?.cancel()
        await pending?.value
    }
}
