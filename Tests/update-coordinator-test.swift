import Foundation

@main @MainActor struct UpdateCoordinatorTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func wait(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !done(), Date() < deadline { await Task.yield() }
        require(done(), "Coordinator did not reach expected suspension")
    }
    static func main() async throws {
        for beforeReplacement in [true, false] {
            let core = AppCore()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let store = UpdateCheckStore(repository: "tehss1/tinycast", channel: .stable,
                runningVersion: AppVersion("1.0.0"), fileURL: file, fetch: {
                    .body(Data("""
                    [{"tag_name":"v1.1.0","prerelease":false,"draft":false,"body":"", "assets":[
                    {"name":"Tinycast-1.1.0.zip","url":"https://api.github.com/assets/1","size":100}]}]
                    """.utf8))
                })
            var installs = 0
            var replacements = 0
            var presentations = 0
            var enteredInstaller = false
            var releaseInstaller: CheckedContinuation<Void, Never>?
            var queued: (@MainActor () -> Bool)?
            var finishRelaunch: CheckedContinuation<Bool, Never>?
            let coordinator = UpdateCoordinator(store: store, core: core, install: { _, _, gate, replaced in
                installs += 1
                enteredInstaller = true
                if beforeReplacement {
                    await withCheckedContinuation { releaseInstaller = $0 }
                    try Task.checkCancellation()
                }
                if try gate() { replacements += 1; replaced() }
            }, scheduleRelaunch: { ready in
                queued = ready
                return await withCheckedContinuation { finishRelaunch = $0 }
            }, isIdle: { true }, present: { presentations += 1 })
            coordinator.releasePublished(bundlePath: "/Applications/Tinycast.app")
            await wait { beforeReplacement ? enteredInstaller : queued != nil }
            coordinator.releasePublished(bundlePath: "/Applications/Tinycast.app")
            require(installs == 1, "Second notification must not install twice")
            coordinator.install()
            coordinator.checkForUpdates()
            coordinator.checkForUpdates()
            require(presentations == 0, "Manual ownership waits for cancellation to finish")
            if beforeReplacement {
                releaseInstaller?.resume()
            } else {
                require(coordinator.stage == .readyToRelaunch, "Replacement recorded synchronously")
                require(queued?() == false, "Queued run-loop callback must reject manual takeover")
                finishRelaunch?.resume(returning: false)
            }
            await wait { presentations == 1 }
            require(installs == 1, "Manual requests adopt installed state without duplicate install")
            require(replacements == (beforeReplacement ? 0 : 1), "Replacement count respects takeover")
            if !beforeReplacement {
                require(presentations == 1, "Only latest repeated manual request proceeds")
                coordinator.install()
                await wait { presentations == 2 }
                require(installs == 1, "Repeated manual install cannot replace again")
            }
        }
        print("Coordinator takeover, queued cancellation, repeated requests and exactly-once install passed")
    }
}
