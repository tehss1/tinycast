import AppKit
import SwiftUI

/// The installer only performs an update the coordinator has decided is safe.
@MainActor
@Observable
final class UpdateCoordinator {
    /// One surface for prompt, progress and report: a download cannot move into a dialog.
    enum Stage: Equatable {
        case checking
        case upToDate
        /// A local build has no release stream to compare against, and says so rather than lying.
        case localBuild
        case available(AvailableRelease)
        case blocked(UpdateReadiness.Blocker, AvailableRelease)
        case installing(AvailableRelease, UpdateInstaller.Phase)
        case readyToRelaunch
        case failed(UpdateFailure)
    }

    private(set) var stage: Stage = .checking

    private let store: UpdateCheckStore
    /// Environment injection and activity reads only — never for state this type owns.
    private unowned let core: AppCore
    @ObservationIgnored private lazy var window = AppWindowController(
        title: String(localized: "Software Update"), contentSize: UpdateWindowView.initialSize,
        activation: core.activationPolicy)
    @ObservationIgnored private var installTask: Task<Void, Never>?

    @ObservationIgnored private var releaseObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var lastReleaseAttempt: Date?
    private var installation = UpdateInstallationState()
    @ObservationIgnored private var manualRequestID = UUID()
    @ObservationIgnored private var manualRequestInFlight = false

    typealias Install = @MainActor (
        AvailableRelease, @escaping @Sendable (UpdateInstaller.Phase) -> Void,
        @escaping @MainActor @Sendable () throws -> Bool,
        @escaping @MainActor @Sendable () -> Void
    ) async throws -> Void
    typealias ScheduleRelaunch = @MainActor (@escaping @MainActor () -> Bool) async -> Bool

    @ObservationIgnored private let installOverride: Install?
    @ObservationIgnored private let scheduleRelaunch: ScheduleRelaunch
    @ObservationIgnored private let idleOverride: (@MainActor () -> Bool)?
    @ObservationIgnored private let presentOverride: (@MainActor () -> Void)?
    @ObservationIgnored private var unattendedID: UUID?

    init(store: UpdateCheckStore, core: AppCore, install: Install? = nil,
         scheduleRelaunch: ScheduleRelaunch? = nil,
         isIdle: (@MainActor () -> Bool)? = nil, present: (@MainActor () -> Void)? = nil) {
        self.store = store
        self.core = core
        installOverride = install
        self.scheduleRelaunch = scheduleRelaunch ?? { [unowned core] ready in
            await core.relaunchInBackgroundIfIdle(whenReady: ready)
        }
        idleOverride = isIdle
        presentOverride = present
    }

    var channel: ReleaseChannel { store.channel }
    var runningVersion: String { store.runningVersion?.description ?? String(localized: "unknown") }

    /// A local build has no release stream, so it does not advertise the command either.
    func applyEnabled() {
        core.appIndex.setCommandsVisible([.checkForUpdates], store.channel.updatesItself)
        guard releaseObserver == nil else { return }
        releaseObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ReleaseUpdatePolicy.notificationName), object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.releasePublished() }
        }
    }

    func applyAutomaticChecking() {
        if !core.settings.automaticallyCheckForUpdates {
            unattendedID = nil
            releaseTask?.cancel()
        }
        if core.settings.automaticallyCheckForUpdates {
            store.start()
        } else {
            store.stop()
        }
    }

    func focusExisting() -> Bool {
        window.focus()
    }

    /// The window takes the height its content measured, so no stage pads itself out with space.
    func fit(height: CGFloat) {
        window.fitContent(width: UpdateWindowView.width, height: height)
    }

    // MARK: - Entry points

    /// The manual action: always opens the window and always asks GitHub.
    func checkForUpdates() {
        takeManualOwnership { $0.checkManually() }
    }

    private func checkManually() {
        if installation.readyToRelaunch {
            stage = .readyToRelaunch
            present()
            return
        }
        guard store.channel.updatesItself else {
            stage = .localBuild
            present()
            return
        }
        if case .installing = stage {
            present()
            return
        }
        stage = .checking
        present()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await store.check()
            guard case .checking = stage else { return }
            if let release = store.update {
                stage = .available(release)
                return
            }
            switch outcome {
            case .answered: stage = .upToDate
            case .refused: stage = .failed(.accessRefused)
            case .missing: stage = .failed(.feedMissing)
            case .limited: stage = .failed(.rateLimited)
            case .busy: stage = .failed(.checkInProgress)
            case .unreachable:
                stage = .failed(.downloadFailed(String(localized: "Tinycast could not reach GitHub.")))
            }
        }
    }

    /// The automatic path: `false` answers that it withheld the prompt, so the store re-offers it.
    func presentIfAvailable(_ release: AvailableRelease) -> Bool {
        guard core.settings.automaticallyCheckForUpdates, releaseTask == nil else { return false }
        switch stage {
        // Already in hand: re-offering would throw away a download or the relaunch it earned.
        case .installing, .readyToRelaunch:
            return true
        case .checking, .upToDate, .localBuild, .available, .blocked, .failed:
            guard UpdateReadiness.evaluate(core.currentActivity) == nil else { return false }
            stage = .available(release)
            present()
            return true
        }
    }

    // MARK: - Actions

    func install() {
        takeManualOwnership { $0.installManually() }
    }

    private func installManually() {
        if installation.readyToRelaunch {
            stage = .readyToRelaunch
            present()
            return
        }
        guard installTask == nil, let release = pendingRelease,
            installation.needsInstallation else { return }
        // Re-asked at the moment of the click, never read from a flag that could have gone stale.
        if let blocker = UpdateReadiness.evaluate(core.currentActivity) {
            stage = .blocked(blocker, release)
            return
        }
        stage = .installing(release, .downloading(received: 0, expected: release.assetSize))
        let install = self.performInstall
        // Hoisted: nesting the hop inside the task body would re-capture its weak `self`.
        let onProgress: @Sendable (UpdateInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, for: release) }
        }
        installTask = Task { [weak self] in
            defer { self?.installTask = nil }
            do {
                try await install(release, onProgress, { true }, { [weak self] in
                    self?.recordReplacement(release)
                })
                self?.stage = .readyToRelaunch
            } catch is CancellationError {
                self?.stage = .available(release)
            } catch let failure as UpdateFailure {
                self?.stage = .failed(failure)
            } catch {
                self?.stage = .failed(.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// Dismissing a version is what stops it asking again; a later one still will.
    func skip() {
        if let release = pendingRelease { store.skip(release) }
        window.close()
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func retry() {
        guard let release = pendingRelease else { return }
        stage = .available(release)
    }

    func dismiss() {
        window.close()
    }

    func relaunch() {
        core.relaunch()
    }

    // MARK: - Private

    private func takeManualOwnership(_ action: @escaping @MainActor (UpdateCoordinator) -> Void) {
        unattendedID = nil
        manualRequestInFlight = true
        manualRequestID = UUID()
        let requestID = manualRequestID
        let pending = releaseTask
        pending?.cancel()
        Task { [weak self] in
            await UpdateManualOwnership.takeOver(from: pending)
            guard let self, manualRequestID == requestID else { return }
            manualRequestInFlight = false
            action(self)
        }
    }

    private func recordReplacement(_ release: AvailableRelease) {
        installation.didReplace(release.version)
        stage = .readyToRelaunch
    }

    func releasePublished(bundlePath: String = Bundle.main.bundleURL.path) {
        guard ReleaseUpdatePolicy.accepts(
            repository: ReleaseFeed.repository, channel: store.channel,
            bundlePath: bundlePath,
            enabled: core.settings.automaticallyCheckForUpdates,
            inFlight: releaseTask != nil || installTask != nil || installation.readyToRelaunch
                || manualRequestInFlight,
            now: Date(), lastAttempt: lastReleaseAttempt
        ) else { return }
        lastReleaseAttempt = Date()
        let operationID = UUID()
        unattendedID = operationID
        releaseTask = Task { [weak self] in
            guard let self else { return }
            defer { releaseTask = nil }
            do {
                while store.isChecking {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                guard await store.check() == .answered, let release = store.update else { return }
                try await waitForIdle(release)
                try await performInstall(release, { _ in }, { [weak self] in
                    guard let self, unattendedID == operationID, !manualRequestInFlight,
                        core.settings.automaticallyCheckForUpdates else {
                        throw CancellationError()
                    }
                    return canInstallRelease(release)
                }, { [weak self] in
                    self?.recordReplacement(release)
                })
                while true {
                    try await waitForIdle(release)
                    let committed = await scheduleRelaunch { [weak self] in
                        guard let self, unattendedID == operationID, !manualRequestInFlight,
                            core.settings.automaticallyCheckForUpdates else { return false }
                        return canInstallRelease(release)
                    }
                    if committed { break }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(2))
                }
            } catch {
                NSLog("Tinycast release update did not complete: %@", String(describing: error))
            }
        }
    }

    private func canInstallRelease(_ release: AvailableRelease) -> Bool {
        if let idleOverride { return idleOverride() }
        return ReleaseUpdatePolicy.canInstall(
            running: store.runningVersion, candidate: release.version, activity: core.currentActivity,
            quickActionBusy: core.quickActionCoordinator.blocksUnattendedUpdate
                || core.dictationCoordinator.isBusyForUpdate,
            hasVisibleWindows: UpdateWindowKind.blocksUpdate(
                NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }.map(\.updateWindowKind)))
    }

    private func waitForIdle(_ release: AvailableRelease) async throws {
        while true {
            try Task.checkCancellation()
            guard core.settings.automaticallyCheckForUpdates else { throw CancellationError() }
            if canInstallRelease(release) { return }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func report(_ phase: UpdateInstaller.Phase, for release: AvailableRelease) {
        guard case .installing = stage else { return }
        stage = .installing(release, phase)
    }

    private var pendingRelease: AvailableRelease? {
        switch stage {
        case .available(let release), .blocked(_, let release), .installing(let release, _):
            return release
        case .checking, .upToDate, .localBuild, .readyToRelaunch, .failed:
            return store.update
        }
    }

    private func performInstall(
        _ release: AvailableRelease, _ progress: @escaping @Sendable (UpdateInstaller.Phase) -> Void,
        _ canReplace: @escaping @MainActor @Sendable () throws -> Bool,
        _ didReplace: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        if let installOverride {
            try await installOverride(release, progress, canReplace, didReplace)
        } else {
            try await installer.install(release, onProgress: progress,
                                        canReplace: canReplace, didReplace: didReplace)
        }
    }

    private var installer: UpdateInstaller {
        UpdateInstaller(
            bundleURL: Bundle.main.bundleURL,
            stagingDirectory: AppPaths.caches().appendingPathComponent("Updates", isDirectory: true),
            token: UpdateToken.read())
    }

    private func present() {
        if let presentOverride { presentOverride(); return }
        window.show {
            UpdateWindowView()
                .environment(self)
        }
    }
}
