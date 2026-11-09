import Foundation

enum DialogTone { case success, neutral, danger }

@MainActor final class AppCore {
    final class Settings { var automaticallyCheckForUpdates = true }
    final class Index { func setCommandsVisible(_ commands: [Command], _ visible: Bool) {} }
    enum Command { case checkForUpdates }
    final class QuickActions { var blocksUnattendedUpdate = false }
    final class Dictation { var isBusyForUpdate = false }
    enum PaletteMode { case launcher }
    final class Palette {
        var isVisible = false
        var shown = 0
        func showPalette(mode: PaletteMode, restoreAnyMode: Bool) { shown += 1 }
    }
    let settings = Settings()
    let appIndex = Index()
    let quickActionCoordinator = QuickActions()
    let dictationCoordinator = Dictation()
    let paletteCoordinator = Palette()
    var currentActivity = UpdateActivity()
    var messages: [String] = []
    func showMessage(_ message: String, tone: DialogTone = .success) { messages.append(message) }
    func showProgress(_ message: String, onCancel: (() -> Void)? = nil) {}
    func hideProgress() {}
    func reportFailure(title: String, message: String, symbol: String, recovery: String?) async -> Bool {
        false
    }
    func relaunch() { fatalError("Unexpected real relaunch") }
    func relaunchInBackgroundIfIdle(whenReady: @escaping @MainActor () -> Bool) async -> Bool {
        fatalError("Tests must inject the scheduler")
    }
}
enum UpdateToken { static func read() -> String? { nil } }
