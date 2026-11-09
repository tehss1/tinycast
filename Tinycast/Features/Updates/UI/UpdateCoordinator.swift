import AppKit
import os

@MainActor
@Observable
final class UpdateCoordinator {
    enum Stage: Equatable {
        case idle
        case checking
        case available(AvailableRelease)
        case installing(AvailableRelease, UpdateInstaller.Phase)
        case readyToRelaunch
        case failed(UpdateFailure)
    }

    private(set) var stage: Stage = .idle

    private let store: UpdateCheckStore
    /// For other features only — never for state this type owns.
    private unowned let core: AppCore
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var staged: UpdateInstaller.Staged?
    private static let logger = Logger(subsystem: "com.tinycast", category: "Updates")

    @ObservationIgnored private var releaseObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var lastReleaseAttempt: Date?
    @ObservationIgnored private var manualRequestID = UUID()
    @ObservationIgnored private var manualRequestInFlight = false
    @ObservationIgnored private var unattendedID: UUID?

    typealias Prepare = @MainActor (
        AvailableRelease, @escaping @Sendable (UpdateInstaller.Phase) -> Void
    ) async throws -> UpdateInstaller.Staged
    typealias ScheduleRelaunch = @MainActor (@escaping @MainActor () -> Bool) async -> Bool

    @ObservationIgnored private let prepareOverride: Prepare?
    @ObservationIgnored private let scheduleRelaunch: ScheduleRelaunch
    @ObservationIgnored private let idleOverride: (@MainActor () -> Bool)?

    init(
        store: UpdateCheckStore, core: AppCore, prepare: Prepare? = nil,
        scheduleRelaunch: ScheduleRelaunch? = nil, isIdle: (@MainActor () -> Bool)? = nil
    ) {
        self.store = store
        self.core = core
        prepareOverride = prepare
        self.scheduleRelaunch = scheduleRelaunch ?? { [unowned core] ready in
            await core.relaunchInBackgroundIfIdle(whenReady: ready)
        }
        idleOverride = isIdle
    }

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
        if core.settings.automaticallyCheckForUpdates {
            store.start()
        } else {
            cancelUnattended()
            store.stop()
        }
    }

    // MARK: - Entry points

    /// Never re-offers an update under way: that would discard it.
    func checkForUpdates() {
        takeManualOwnership { $0.checkManually() }
    }

    private func checkManually() {
        guard store.channel.updatesItself else {
            core.showMessage(
                String(localized: "This is a local build — rebuild it to move it forward."),
                tone: .neutral)
            return
        }
        if staged != nil { stage = .readyToRelaunch }
        switch stage {
        case .installing, .readyToRelaunch:
            showPill()
        case .checking:
            break
        case .idle, .available, .failed:
            check()
        }
    }

    /// The automatic path: the pill waits for the next palette open and never interrupts.
    func offer(_ release: AvailableRelease) {
        guard core.settings.automaticallyCheckForUpdates, staged == nil, releaseTask == nil else {
            return
        }
        switch stage {
        case .checking, .installing, .readyToRelaunch:
            break
        case .idle, .available, .failed:
            stage = .available(release)
        }
    }

    // MARK: - Actions

    func install() {
        takeManualOwnership { $0.installManually() }
    }

    private func installManually() {
        if staged != nil {
            stage = .readyToRelaunch
            return
        }
        guard let release = pendingRelease else { return }
        stage = .installing(release, .downloading(received: 0, expected: release.assetSize))
        // Hoisted: nesting the hop inside the task body would re-capture its weak `self`.
        let onProgress: @Sendable (UpdateInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, for: release) }
        }
        let prepare = self.prepare
        installTask = Task { [weak self] in
            do {
                let staged = try await prepare(release, onProgress)
                self?.didStage(staged, of: release)
            } catch is CancellationError {
                self?.stage = .available(release)
            } catch let failure as UpdateFailure {
                self?.stage = .failed(failure)
            } catch {
                self?.stage = .failed(.downloadFailed(error.localizedDescription))
            }
        }
    }

    func dismiss() {
        switch stage {
        case .installing:
            installTask?.cancel()
            installTask = nil
        case .readyToRelaunch:
            // "Later" is an answer: the update still lands at the next quit, but not on its own.
            cancelUnattended()
            stage = .idle
        case .available, .failed:
            stage = .idle
        case .idle, .checking:
            break
        }
    }

    func showFailure() {
        guard case .failed(let failure) = stage else { return }
        let message = [failure.errorDescription, failure.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
        Task {
            let retry = await core.reportFailure(
                title: String(localized: "Update failed"), message: message,
                symbol: "arrow.down.circle", recovery: String(localized: "Try Again"))
            if retry, case .failed = stage { install() }
        }
    }

    func relaunch() {
        core.relaunch()
    }

    func installStagedUpdate() {
        guard let staged else { return }
        self.staged = nil
        do {
            try installer.install(staged)
        } catch {
            Self.logger.error(
                "Installing the staged update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Unattended install

    /// A release from this Mac's own script. Staging touches nothing, so only the relaunch waits.
    func releasePublished(bundlePath: String = Bundle.main.bundleURL.path) {
        guard
            ReleaseUpdatePolicy.accepts(
                repository: ReleaseFeed.repository, channel: store.channel,
                bundlePath: bundlePath,
                enabled: core.settings.automaticallyCheckForUpdates,
                inFlight: releaseTask != nil || isInstalling || staged != nil
                    || manualRequestInFlight,
                now: Date(), lastAttempt: lastReleaseAttempt)
        else { return }
        lastReleaseAttempt = Date()
        let operationID = UUID()
        unattendedID = operationID
        let prepare = self.prepare
        releaseTask = Task { [weak self] in
            guard let self else { return }
            defer { releaseTask = nil }
            do {
                guard await store.check() == .answered, let release = store.update else { return }
                try Task.checkCancellation()
                let staged = try await prepare(release, { _ in })
                try Task.checkCancellation()
                guard isCurrent(operationID) else { throw CancellationError() }
                didStage(staged, of: release)
                try await relaunchWhenIdle(release, operationID)
            } catch {
                Self.logger.error(
                    "Release update did not complete: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func relaunchWhenIdle(_ release: AvailableRelease, _ operationID: UUID) async throws {
        while true {
            try await waitForIdle(release)
            let committed = await scheduleRelaunch { [weak self] in
                guard let self, isCurrent(operationID) else { return false }
                return canInstallRelease(release)
            }
            if committed { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        unattendedID == operationID && !manualRequestInFlight
            && core.settings.automaticallyCheckForUpdates
    }

    private func canInstallRelease(_ release: AvailableRelease) -> Bool {
        if let idleOverride { return idleOverride() }
        return ReleaseUpdatePolicy.canInstall(
            running: store.runningVersion, candidate: release.version,
            activity: core.currentActivity,
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

    private func cancelUnattended() {
        unattendedID = nil
        releaseTask?.cancel()
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

    private func didStage(_ staged: UpdateInstaller.Staged, of release: AvailableRelease) {
        self.staged = staged
        store.recordInstall(of: release.version)
        stage = .readyToRelaunch
    }

    private var isInstalling: Bool {
        if case .installing = stage { return true }
        return false
    }

    private func check() {
        stage = .checking
        core.showProgress(String(localized: "Checking for updates…"))
        Task { [weak self] in
            guard let self else { return }
            let outcome = await store.check()
            if let release = store.update {
                core.hideProgress()
                stage = .available(release)
                showPill()
                return
            }
            stage = .idle
            switch outcome {
            case .answered:
                core.showMessage(String(localized: "\(Bundle.main.appDisplayName) is up to date"))
            case .refused: reportCheckFailure(.accessRefused)
            case .missing: reportCheckFailure(.feedMissing)
            case .limited: reportCheckFailure(.rateLimited)
            case .unreachable:
                core.showMessage(
                    String(localized: "Tinycast could not reach GitHub."), tone: .danger)
            }
        }
    }

    private func reportCheckFailure(_ failure: UpdateFailure) {
        core.showMessage(failure.errorDescription ?? "", tone: .danger)
    }

    private func showPill() {
        guard !core.paletteCoordinator.isVisible else { return }
        core.paletteCoordinator.showPalette(mode: .launcher, restoreAnyMode: true)
    }

    private func report(_ phase: UpdateInstaller.Phase, for release: AvailableRelease) {
        guard case .installing = stage else { return }
        stage = .installing(release, phase)
    }

    private var pendingRelease: AvailableRelease? {
        switch stage {
        case .available(let release), .installing(let release, _):
            return release
        case .idle, .checking, .readyToRelaunch, .failed:
            return store.update
        }
    }

    private var prepare: Prepare {
        if let prepareOverride { return prepareOverride }
        let installer = self.installer
        return { release, progress in
            try await installer.prepare(release, onProgress: progress)
        }
    }

    private var installer: UpdateInstaller {
        UpdateInstaller(
            bundleURL: Bundle.main.bundleURL,
            stagingDirectory: AppPaths.caches().appendingPathComponent("Updates", isDirectory: true),
            token: UpdateToken.read())
    }
}
