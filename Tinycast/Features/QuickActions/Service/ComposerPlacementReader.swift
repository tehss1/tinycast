import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum ComposerPlacementReader {
    static func frame(in app: NSRunningApplication?, editor: AXUIElement?) -> CGRect? {
        guard let app, !app.isTerminated else { return nil }
        let application = AXWindowAccess.application(for: app.processIdentifier)
        let editor = editor ?? AccessibilityText.focusedElement(in: app)
        let window = editor.flatMap { AXWindowAccess.element($0, kAXWindowAttribute) }
            ?? AXWindowAccess.targetWindow(in: application)
        if let window {
            AXUIElementSetMessagingTimeout(window, AXWindowAccess.messagingTimeout)
        }
        guard let source = ComposerPanelPlacement.sourceFrame(
            editor: editor.flatMap { AXWindowAccess.frame(of: $0) },
            window: window.flatMap { AXWindowAccess.frame(of: $0) })
        else { return nil }
        return AXGeometry(screens: NSScreen.screens).flip(source)
    }
}
