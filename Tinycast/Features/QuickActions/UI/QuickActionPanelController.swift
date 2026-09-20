import AppKit
import SwiftUI

/// Owns the result panel: one at a time, and the target app keeps its selection while it is up.
@MainActor
final class QuickActionPanelController: NSObject, NSWindowDelegate {
    private var panel: QuickActionPanel?
    private var state: QuickActionPanelState?
    private var onReplace: ((String) -> Void)?
    private var onRetranslate: ((Locale.Language) -> Void)?
    private var onDismiss: (() -> Void)?
    private var selectedOutput = ""
    private var isViewingActiveConversation = true

    /// Clear of the pointer, so the panel never opens under the hand that summoned it.
    private static let cursorOffset: CGFloat = 12
    private static let screenMargin: CGFloat = 8
    private static let languageSettingsPane = "com.apple.Localization-Settings.extension"

    func present(
        _ state: QuickActionPanelState,
        coordinator: QuickActionCoordinator,
        history: RewriteHistoryStore,
        palette: PaletteState,
        metrics: InterfaceMetrics,
        languages: [Locale.Language],
        sourceFrame: CGRect?,
        onRetranslate: @escaping (Locale.Language) -> Void,
        onRefine: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onInstructionChange: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onDeleteHistory: @escaping (UUID) -> Bool,
        onReplace: @escaping (String) -> Void
    ) {
        dismiss()
        self.state = state
        self.onReplace = onReplace
        self.onRetranslate = onRetranslate
        self.onDismiss = onDismiss

        let hosting = NSHostingView(
            rootView: QuickActionResultView(
                state: state,
                history: history,
                languages: languages,
                onRefine: onRefine,
                onStop: onStop,
                onInstructionChange: onInstructionChange,
                onReplace: { [weak self] in self?.replace(state.output) },
                onCopy: { [weak self] in self?.copyOutput($0) },
                onDeleteHistory: onDeleteHistory,
                onSelectionChange: { [weak self] text, isViewingActive in
                    self?.selectedOutput = text
                    self?.isViewingActiveConversation = isViewingActive
                },
                onCancel: { [weak self] in self?.dismiss() },
                onRetranslate: { [weak self] in self?.onRetranslate?($0) },
                onOpenLanguageSettings: { [weak self] in self?.openLanguageSettings() },
                onHeight: { [weak self] in self?.resize(toHeight: $0) }
            )
            .environment(\.metrics, metrics)
            .environment(coordinator)
            .environment(palette))
        // The controller owns the frame; without this the top edge drifts as the reply grows.
        hosting.sizingOptions = []
        // Its tallest, so the first frame is never short; the view reports the real height at once.
        let width = metrics.size.quickActionPanel
            + (state.action == .rewrite
                ? metrics.size.quickActionHistorySidebar + Theme.Size.hairline : 0)
        hosting.setFrameSize(NSSize(width: width, height: metrics.size.quickActionPanelBody))

        let panel = QuickActionPanel(content: hosting)
        panel.onAccessoryKey = { [weak state, weak coordinator] event in
            guard let state, let coordinator else { return nil }
            return ComposerToolbar.handleKey(event, state: state, coordinator: coordinator)
        }
        panel.delegate = self
        panel.onKey = { [weak self] key in
            guard let self, let state = self.state else { return }
            switch key {
            case .replace:
                if state.canDeliver(isViewingActive: self.isViewingActiveConversation) {
                    self.replace(state.output)
                }
            case .copy: self.copyOutput(self.selectedOutput)
            case .cancel: self.dismiss()
            }
        }
        self.panel = panel
        if state.action == .rewrite {
            placeOverSource(panel, sourceFrame: sourceFrame)
        } else {
            placeAtCursor(panel)
        }
        // Non-activating like the palette: key focus without pulling the reader out of their app.
        panel.fadeIn(duration: Theme.Duration.enter) {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    func dismiss(preservingDraft: Bool = true) {
        guard let closing = panel else { return }
        let preserveDraft = preservingDraft ? onDismiss : nil
        panel = nil
        state = nil
        onReplace = nil
        onRetranslate = nil
        onDismiss = nil
        selectedOutput = ""
        isViewingActiveConversation = true
        closing.delegate = nil
        closing.onKey = nil
        closing.onAccessoryKey = nil
        preserveDraft?()
        closing.fadeOut(duration: Theme.Duration.exit)
    }

    private func copyOutput(_ text: String) {
        guard !text.isEmpty else { return }
        Paster.copyPlainText(text)
    }

    private func openLanguageSettings() {
        dismiss()
        AppLauncher.openSettingsPane(bundleID: Self.languageSettingsPane)
    }

    private func replace(_ text: String) {
        let callback = onReplace
        dismiss()
        callback?(text)
    }

    /// Grows from the current top-left, so a reply landing after a drag cannot snap the panel back.
    private func resize(toHeight height: CGFloat) {
        guard let panel, height > 0, abs(height - panel.frame.height) > 0.5 else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let width = panel.frame.width
        panel.setFrame(
            NSRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height),
            display: true)
        clampOnScreen(panel)
    }

    private func placeAtCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: mouse.x + Self.cursorOffset,
                y: mouse.y - Self.cursorOffset - size.height))
        clampOnScreen(panel)
    }

    private func placeOverSource(_ panel: NSPanel, sourceFrame: CGRect?) {
        let screens = NSScreen.screens
        let source = sourceFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.primary?.visibleFrame
        guard let source,
            let index = ComposerPanelPlacement.screenIndex(for: source, screens: screens.map(\.frame))
        else { return }
        panel.setFrame(
            ComposerPanelPlacement.centeredFrame(
                size: panel.frame.size, source: source, visibleScreen: screens[index].visibleFrame,
                margin: Self.screenMargin),
            display: false)
    }

    private func clampOnScreen(_ panel: NSPanel) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = panel.frame
        let clamped = ComposerPanelPlacement.clamped(frame, to: visible, margin: Self.screenMargin)
        guard clamped.origin != frame.origin else { return }
        panel.setFrameOrigin(clamped.origin)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        dismiss()
    }
}
