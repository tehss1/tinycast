import AppKit

@MainActor
protocol UpdateWorkWindow: AnyObject {}

extension NSWindow {
    var updateWindowKind: UpdateWindowKind {
        self is any UpdateWorkWindow || self is NSSavePanel ? .work : .statusItemHost
    }
}
