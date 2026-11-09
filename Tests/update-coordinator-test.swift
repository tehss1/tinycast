import Foundation

@MainActor final class Harness {
    let core = AppCore()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let staged = UpdateInstaller.Staged(
        app: URL(fileURLWithPath: "/nonexistent/Tinycast.app"), isReleaseSigned: false, codeHash: Data())
    var prepares = 0
    var enteredPrepare = false
    var failPrepare = false
    var holdPrepare = false
    var idle = true
    var scheduled = 0
    var holdFetch = false
    var heldFetches: [CheckedContinuation<Void, Never>] = []
    var releasePrepare: CheckedContinuation<Void, Never>?
    var queued: (@MainActor () -> Bool)?
    var finishRelaunch: CheckedContinuation<Bool, Never>?
    private(set) lazy var store = UpdateCheckStore(
        repository: "tehss1/tinycast", channel: .stable, runningVersion: AppVersion("1.0.0"),
        fileURL: file,
        fetch: { [unowned self] in await respond() })
    private(set) lazy var coordinator = UpdateCoordinator(
        store: store, core: core,
        prepare: { [unowned self] _, _ in
            prepares += 1
            enteredPrepare = true
            if holdPrepare {
                await withCheckedContinuation { releasePrepare = $0 }
                try Task.checkCancellation()
            }
            if failPrepare { throw UpdateFailure.identityMismatch }
            return staged
        },
        scheduleRelaunch: { [unowned self] ready in
            scheduled += 1
            queued = ready
            return await withCheckedContinuation { finishRelaunch = $0 }
        },
        isIdle: { [unowned self] in idle })
    var pills: Int { core.paletteCoordinator.shown }

    func respond() async -> ReleaseFeed.Response {
        if holdFetch { await withCheckedContinuation { heldFetches.append($0) } }
        return .body(Data("""
        [{"tag_name":"v1.1.0","prerelease":false,"draft":false,"body":"", "assets":[
        {"name":"Tinycast-1.1.0.zip","url":"https://api.github.com/assets/1","size":100}]}]
        """.utf8))
    }

    func publish() { coordinator.releasePublished(bundlePath: "/Applications/Tinycast.app") }
    deinit { try? FileManager.default.removeItem(at: file) }
}

@main @MainActor struct UpdateCoordinatorTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func wait(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { await Task.yield() }
        require(done(), "Coordinator did not reach expected suspension")
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    static func main() async throws {
        try await manualTakeoverBeforeStaging()
        try await queuedRelaunchRejectedAfterTakeover()
        try await laterStopsTheRelaunchButKeepsTheUpdate()
        try await stagingDoesNotWaitForIdle()
        try await turningUpdatesOffStopsTheRelaunch()
        try await failedStagingStaysSilent()
        try await manualCheckKeepsUnattendedWorkOut()
        try await dismissingAnOfferStopsSilentStaging()
        print("Coordinator takeover, queued cancellation, Later, idle gating and exactly-once staging passed")
    }

    static func manualTakeoverBeforeStaging() async throws {
        let h = Harness()
        h.holdPrepare = true
        h.publish()
        await wait { h.enteredPrepare }
        h.publish()
        require(h.prepares == 1, "A second notification must not stage twice")
        h.coordinator.install()
        h.coordinator.checkForUpdates()
        h.coordinator.checkForUpdates()
        try await settle()
        require(h.pills == 0, "Manual ownership waits for the cancelled staging to finish")
        h.releasePrepare?.resume()
        await wait { h.pills == 1 }
        try await settle()
        require(h.pills == 1, "Only the latest repeated manual request proceeds")
        require(h.prepares == 1, "A superseded manual install never stages")
        require(h.queued == nil, "A cancelled staging never schedules a relaunch")
        guard case .available = h.coordinator.stage else { fatalError("Manual check offers the release") }
    }

    static func queuedRelaunchRejectedAfterTakeover() async throws {
        let h = Harness()
        h.publish()
        await wait { h.queued != nil }
        require(h.coordinator.stage == .readyToRelaunch, "Staging records the ready stage")
        h.publish()
        require(h.prepares == 1, "A staged update refuses another notification")
        h.coordinator.checkForUpdates()
        h.coordinator.checkForUpdates()
        require(h.queued?() == false, "A queued relaunch must reject a manual takeover")
        h.finishRelaunch?.resume(returning: false)
        await wait { h.pills == 1 }
        require(h.coordinator.stage == .readyToRelaunch, "A manual request adopts the staged update")
        h.coordinator.install()
        try await settle()
        require(h.prepares == 1, "A manual install adopts the staged update")
        require(h.coordinator.stage == .readyToRelaunch, "A repeated install stays ready")
        require(h.scheduled == 1, "A takeover ends the automatic relaunch")
    }

    static func laterStopsTheRelaunchButKeepsTheUpdate() async throws {
        let h = Harness()
        h.publish()
        await wait { h.queued != nil }
        h.coordinator.dismiss()
        require(h.coordinator.stage == .idle, "Later hides the pill")
        require(h.queued?() == false, "Later rejects a relaunch already queued")
        h.finishRelaunch?.resume(returning: false)
        try await settle()
        require(h.scheduled == 1, "Later stops the relaunch loop")
        h.publish()
        try await settle()
        require(h.prepares == 1, "Later keeps the staged update for the next quit")
        h.coordinator.checkForUpdates()
        await wait { h.pills == 1 }
        require(h.coordinator.stage == .readyToRelaunch, "Asking again finds the staged update")
    }

    static func stagingDoesNotWaitForIdle() async throws {
        let h = Harness()
        h.idle = false
        h.publish()
        await wait { h.coordinator.stage == .readyToRelaunch }
        require(h.prepares == 1, "Staging proceeds while the app is busy")
        require(h.queued == nil, "The relaunch waits for idle")
        h.idle = true
        await wait { h.queued != nil }
        require(h.queued?() == true, "An idle app may relaunch")
        h.finishRelaunch?.resume(returning: true)
        try await settle()
        require(h.scheduled == 1, "A committed relaunch is scheduled once")
    }

    static func turningUpdatesOffStopsTheRelaunch() async throws {
        let h = Harness()
        h.publish()
        await wait { h.queued != nil }
        h.core.settings.automaticallyCheckForUpdates = false
        h.coordinator.applyAutomaticChecking()
        require(h.queued?() == false, "Turning updates off rejects a queued relaunch")
        h.finishRelaunch?.resume(returning: false)
        try await settle()
        require(h.scheduled == 1, "Turning updates off stops the relaunch loop")

        let off = Harness()
        off.core.settings.automaticallyCheckForUpdates = false
        off.publish()
        try await settle()
        require(off.prepares == 0, "A disabled updater ignores release notifications")
    }

    static func manualCheckKeepsUnattendedWorkOut() async throws {
        let h = Harness()
        h.holdFetch = true
        h.coordinator.checkForUpdates()
        await wait { h.heldFetches.count == 1 }
        h.publish()
        try await settle()
        require(h.heldFetches.count == 1, "A notification waits out a manual check already asking")
        require(h.prepares == 0, "A manual check is never raced by unattended staging")
        h.holdFetch = false
        h.heldFetches.removeFirst().resume()
        await wait { h.pills == 1 }
        guard case .available = h.coordinator.stage else { fatalError("Manual check offers the release") }
        require(h.queued == nil, "A manual check never schedules a relaunch")
    }

    static func dismissingAnOfferStopsSilentStaging() async throws {
        let h = Harness()
        h.holdPrepare = true
        h.coordinator.offer(AvailableRelease(
            version: AppVersion("1.1.0")!, tag: "v1.1.0",
            assetURL: URL(string: "https://api.github.com/assets/1")!, assetSize: 100,
            signatureURL: nil, publishedAt: nil))
        h.publish()
        await wait { h.enteredPrepare }
        guard case .available = h.coordinator.stage else { fatalError("The offer stays on screen") }
        h.coordinator.dismiss()
        h.releasePrepare?.resume()
        try await settle()
        require(h.coordinator.stage == .idle, "Dismissing an offer stops staging behind it")
        require(h.queued == nil, "Dismissing an offer stops the relaunch behind it")
    }

    static func failedStagingStaysSilent() async throws {
        let h = Harness()
        h.failPrepare = true
        h.publish()
        await wait { h.enteredPrepare }
        try await settle()
        require(h.coordinator.stage == .idle, "An unattended failure never surfaces a stage")
        require(h.core.messages.isEmpty, "An unattended failure never interrupts")
        require(h.queued == nil, "A failed staging never relaunches")
    }
}
