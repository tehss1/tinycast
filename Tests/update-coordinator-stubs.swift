import AppKit
import SwiftUI

@MainActor final class AppCore {
    final class Settings { var automaticallyCheckForUpdates = true }
    final class Index { func setCommandsVisible(_ commands: [Command], _ visible: Bool) {} }
    enum Command { case checkForUpdates }
    final class QuickActions { var blocksUnattendedUpdate = false }
    final class Dictation { var isBusyForUpdate = false }
    let settings = Settings()
    let appIndex = Index()
    let quickActionCoordinator = QuickActions()
    let dictationCoordinator = Dictation()
    var currentActivity = UpdateActivity()
    var activationPolicy = 0
    func relaunch() { fatalError("Unexpected real relaunch") }
    func relaunchInBackgroundIfIdle(whenReady: @escaping @MainActor () -> Bool) async -> Bool {
        fatalError("Tests must inject the scheduler")
    }
}
@MainActor final class AppWindowController {
    init(title: String, contentSize: CGSize, activation: Int) {}
    func focus() -> Bool { false }
    func fitContent(width: CGFloat, height: CGFloat) {}
    func close() {}
    func show<Content: View>(@ViewBuilder _ content: () -> Content) {
        fatalError("Tests must inject presentation")
    }
}
struct UpdateWindowView: View {
    static let initialSize = CGSize(width: 400, height: 300)
    static let width: CGFloat = 400
    var body: some View { EmptyView() }
}
enum UpdateToken { static func read() -> String? { nil } }
