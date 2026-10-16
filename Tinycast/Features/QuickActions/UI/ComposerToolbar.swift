import SwiftUI
import Carbon.HIToolbox

struct ComposerToolbar: View {
    @Environment(QuickActionCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    @Bindable var state: QuickActionPanelState
    let isViewingActive: Bool

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            Button {
                ComposerToolbar.toggle(.context, state: state, coordinator: coordinator)
            } label: {
                HStack(spacing: metrics.spacing.sm) {
                    SymbolImage(name: contextSymbol, size: metrics.size.quickActionHeaderIcon)
                    Text(contextTitle)
                    SymbolImage(name: "chevron.down", size: metrics.size.quickActionHeaderIcon)
                }
            }
            .accessibilityLabel("\(contextTitle). Show captured context")

            if isViewingActive {
                ComposerAccessoryButton(
                    title: audienceTitle, label: "Audience tone", accessory: .audience,
                    state: state)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
    }

    private var contextTitle: String {
        guard isViewingActive else { return "Saved conversation" }
        return state.context?.captureTitle
            ?? (coordinator.usesOutlookContext ? "Email context unavailable" : "Email context off")
    }

    private var contextSymbol: String {
        state.context?.isComplete == true && isViewingActive
            ? "checkmark.circle" : "info.circle"
    }

    private var audienceTitle: String {
        let title = coordinator.composerAudience(for: state).title
        return state.audienceOverride == nil ? title : "\(title) (Manual)"
    }

    private static let checkmark = "✓"

    private static func mark(_ isChosen: Bool) -> String? {
        isChosen ? checkmark : nil
    }

    static func toggle(
        _ accessory: QuickActionPanelState.Accessory, state: QuickActionPanelState,
        coordinator: QuickActionCoordinator
    ) {
        if accessory == .model { coordinator.prepareComposerModels() }
        state.accessory = state.accessory == accessory ? nil : accessory
        state.accessorySelection = menuItems(state: state, coordinator: coordinator)
            .firstIndex { $0.detail == checkmark } ?? 0
    }

    private static func claudeSetupItems(coordinator: QuickActionCoordinator) -> [PopoverMenuItem] {
        guard let setup = coordinator.composerClaudeSetup else { return [] }
        let title: String
        switch setup {
        case .turnOn: title = "Turn On Claude"
        case .checking: title = "Checking Claude…"
        case .signIn: title = "Sign In to Claude…"
        case .install: title = "Install Claude Code…"
        case .failed(let message): title = message
        }
        var isActionable = true
        if case .failed = setup { isActionable = false }
        return [PopoverMenuItem(
            title: title, icon: .blank, isLoading: setup == .checking, isEnabled: isActionable,
            sectionTitle: "Claude"
        ) { coordinator.performComposerClaudeSetup(setup) }]
    }

    static func menuItems(
        state: QuickActionPanelState, coordinator: QuickActionCoordinator
    ) -> [PopoverMenuItem] {
        switch state.accessory {
        case .audience:
            let detected = coordinator.detectedComposerAudience(for: state)
            return [
                PopoverMenuItem(
                    title: "Automatic (\(detected.title))", icon: .blank,
                    detail: mark(state.audienceOverride == nil)
                ) { coordinator.selectComposerAudience(nil, for: state) },
                PopoverMenuItem(
                    title: "Internal", icon: .blank,
                    detail: mark(state.audienceOverride == .internalRecipients)
                ) { coordinator.selectComposerAudience(.internalRecipients, for: state) },
                PopoverMenuItem(
                    title: "External", icon: .blank,
                    detail: mark(state.audienceOverride == .externalRecipients)
                ) { coordinator.selectComposerAudience(.externalRecipients, for: state) }
            ]
        case .model:
            let items = coordinator.composerModelGroups.flatMap { group in
                group.options.enumerated().map { index, option in
                    PopoverMenuItem(title: option.title, icon: option.menuIcon,
                        sectionTitle: index == 0 ? group.title : nil,
                        detail: mark(coordinator.composerModel.map { option.matches($0) } == true)
                    ) { coordinator.selectComposerModel(option) }
                }
            }
            let all = items + claudeSetupItems(coordinator: coordinator)
            return all.isEmpty
                ? [PopoverMenuItem(title: "No models available. Check AI Settings.", icon: .blank,
                    isEnabled: false) {}] : all
        case .reasoning:
            return coordinator.composerEfforts.map { effort in
                PopoverMenuItem(title: effort.title, icon: .blank,
                    detail: mark(coordinator.composerModel?.effort == effort.id)
                ) { coordinator.selectComposerEffort(effort) }
            }
        case .history(let id):
            return [PopoverMenuItem(
                title: "Delete Conversation", systemImage: "trash", isDestructive: true
            ) { coordinator.deleteComposerConversation(id, from: state) }]
        case .context, nil: return []
        }
    }

    static func handleKey(
        _ event: NSEvent, state: QuickActionPanelState,
        coordinator: QuickActionCoordinator) -> Bool?
    {
        guard state.accessory != nil else {
            return opensConversationMenu(event, state: state) ? true : nil
        }
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            state.accessory = nil
            return true
        }
        let items = menuItems(state: state, coordinator: coordinator)
        if key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            // Command+Return belongs to the panel's Insert/Replace shortcut, not this menu.
            if event.modifierFlags.contains(.command) { return nil }
            if items.indices.contains(state.accessorySelection),
                items[state.accessorySelection].isSelectable
            { items[state.accessorySelection].action() }
            state.accessory = nil
            return true
        }
        if key == kVK_UpArrow || key == kVK_DownArrow, !items.isEmpty {
            state.accessorySelection = min(max(state.accessorySelection
                + (key == kVK_UpArrow ? -1 : 1), 0), items.count - 1)
            return true
        }
        return state.accessory != .context
    }

    /// Left to a field being edited, where ⌘⌫ deletes to the start of the line.
    private static func opensConversationMenu(
        _ event: NSEvent, state: QuickActionPanelState
    ) -> Bool {
        let key = Int(event.keyCode)
        guard state.action == .rewrite,
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
            key == kVK_Delete || key == kVK_ForwardDelete,
            (event.window?.firstResponder as? NSTextView)?.isFieldEditor != true
        else { return false }
        state.accessorySelection = 0
        state.accessory = .history(state.viewedHistoryID ?? state.historyID)
        return true
    }

    struct AccessoryView: View {
        @Environment(QuickActionCoordinator.self) private var coordinator
        @Environment(\.metrics) private var metrics
        @Bindable var state: QuickActionPanelState
        let isViewingActive: Bool
        let maximumHeight: CGFloat

        var body: some View {
            if state.accessory == .context {
                VStack(alignment: .leading, spacing: metrics.spacing.md) {
                    HStack {
                        Text("Email context").font(metrics.typography.sectionHeader)
                        Spacer()
                        Button("Close") { state.accessory = nil }.buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(details)
                            .font(metrics.typography.rowTrailing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: metrics.size.quickActionRewriteMinBody)
                }
                .padding(metrics.spacing.xl)
                .frame(width: metrics.size.quickActionPanel - metrics.spacing.xxl * 2)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: metrics.radius.menuPanel))
            } else {
                let items = ComposerToolbar.menuItems(state: state, coordinator: coordinator)
                PopoverMenu(header: menuTitle,
                    items: items, selection: $state.accessorySelection, maximumHeight: maximumHeight
                ) { index in
                    guard items.indices.contains(index), items[index].isSelectable else { return }
                    items[index].action()
                    state.accessory = nil
                }
            }
        }

        private var menuTitle: String {
            switch state.accessory {
            case .audience: "Audience tone"
            case .model: "Composer model"
            case .reasoning: "Reasoning level"
            case .history: "Conversation"
            case .context, nil: "Composer"
            }
        }

        private var details: String {
            guard isViewingActive else {
                return "Quoted email context is not saved in history. "
                    + "Open this email in Outlook and run Composer to capture its current context."
            }
            guard let context = state.context else {
                return coordinator.usesOutlookContext
                    ? "No Outlook email context was captured. "
                        + "Focus the reply body in Outlook and reopen Composer."
                    : "Outlook context is off. "
                        + "Enable Use Outlook context for Composer in Quick Actions settings."
            }
            let thread = context.recentThread ?? "No quoted messages captured. This may be a new email."
            return "Snapshot from when Composer opened. "
                + "Only the captured text below accompanies your request.\n\n"
                + "Recipients: \(context.recipient ?? "Not captured")\n\n"
                + "Subject: \(context.subject ?? "Not captured")\n\n"
                + "Recent messages:\n\(thread)"
        }
    }
}

struct ComposerModelControls: View {
    @Environment(QuickActionCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    @Bindable var state: QuickActionPanelState

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            ComposerAccessoryButton(
                title: coordinator.composerModelTitle, label: "Composer model", accessory: .model,
                state: state)
            if !coordinator.composerEfforts.isEmpty {
                ComposerAccessoryButton(
                    title: coordinator.composerEffortTitle, label: "Reasoning level",
                    accessory: .reasoning, state: state)
            }
        }
        .buttonStyle(.plain)
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .disabled(state.isRunning)
        .help(
            "Model and reasoning apply to the next Composer request. "
                + "Chat settings are unchanged.")
    }

}

struct ComposerAccessoryButton: View {
    @Environment(QuickActionCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    let title: String
    let label: String
    let accessory: QuickActionPanelState.Accessory
    let state: QuickActionPanelState

    var body: some View {
        Button {
            ComposerToolbar.toggle(accessory, state: state, coordinator: coordinator)
        } label: {
            HStack(spacing: metrics.spacing.sm) {
                Text(title).lineLimit(1).truncationMode(.middle)
                SymbolImage(name: "chevron.down", size: metrics.size.quickActionHeaderIcon)
            }
            .padding(.horizontal, metrics.spacing.md)
            .frame(height: metrics.size.barButtonHeight)
            .background(Theme.Colors.controlSurface,
                in: RoundedRectangle(cornerRadius: metrics.radius.barControl, style: .continuous))
        }
        .accessibilityLabel("\(label): \(title)")
        .disabled(state.isRunning)
    }
}
