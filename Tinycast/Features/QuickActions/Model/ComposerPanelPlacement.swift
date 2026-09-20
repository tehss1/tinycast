import CoreGraphics
import Foundation

enum ComposerPanelPlacement {
    static func sourceFrame(editor: CGRect?, window: CGRect?) -> CGRect? {
        let editor = editor.flatMap { isUsable($0) ? $0 : nil }
        let window = window.flatMap { isUsable($0) ? $0 : nil }
        if let editor, let window {
            let visible = editor.intersection(window)
            return isUsable(visible) ? visible : window
        }
        return editor ?? window
    }

    static func screenIndex(for source: CGRect, screens: [CGRect]) -> Int? {
        screens.indices.max { first, second in
            overlap(source, screens[first]) < overlap(source, screens[second])
        }
    }

    static func centeredFrame(size: CGSize, source: CGRect, visibleScreen: CGRect, margin: CGFloat)
        -> CGRect
    {
        let intersection = source.intersection(visibleScreen)
        let anchor = isUsable(intersection) ? intersection : visibleScreen
        let frame = CGRect(
            x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2,
            width: size.width, height: size.height)
        return clamped(frame, to: visibleScreen, margin: margin)
    }

    static func clamped(_ frame: CGRect, to screen: CGRect, margin: CGFloat) -> CGRect {
        CGRect(
            x: min(max(frame.minX, screen.minX + margin),
                max(screen.maxX - frame.width - margin, screen.minX + margin)),
            y: min(max(frame.minY, screen.minY + margin),
                max(screen.maxY - frame.height - margin, screen.minY + margin)),
            width: frame.width, height: frame.height)
    }

    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return isUsable(intersection) ? intersection.width * intersection.height : 0
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }
}
