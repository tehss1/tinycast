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
                toggle(.context)
            } label: {
                HStack(spacing: metrics.spacing.sm) {
                    SymbolImage(name: contextSymbol, size: metrics.size.quickActionHeaderIcon)
                    Text(contextTitle)
                    SymbolImage(name: "chevron.down", size: metrics.size.quickActionHeaderIcon)
                }
            }
            .accessibilityLabel("\(contextTitle). Show captured context")

            control(audienceTitle, label: "Audience tone", accessory: .audience)
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
        state.context?.captureTitle == "Email context captured" && isViewingActive
            ? "checkmark.circle" : "info.circle"
    }

    private var audienceTitle: String {
        let title = coordinator.composerAudience(for: state).title
        return state.audienceOverride == nil ? title : "\(title) (Manual)"
    }

    private func control(
        _ title: String, label: String, accessory: QuickActionPanelState.Accessory
    ) -> some View {
        Button { toggle(accessory) } label: {
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

    private func toggle(_ accessory: QuickActionPanelState.Accessory) {
        state.accessory = state.accessory == accessory ? nil : accessory
        state.accessorySelection = ComposerToolbar.menuItems(state: state, coordinator: coordinator)
            .firstIndex { $0.detail == "✓" } ?? 0
    }

    static func menuItems(state: QuickActionPanelState, coordinator: QuickActionCoordinator) -> [PopoverMenuItem] {
        switch state.accessory {
        case .audience:
            let detected = coordinator.detectedComposerAudience(for: state)
            return [
                PopoverMenuItem(
                    title: "Automatic (\(detected.title))", icon: .blank,
                    detail: state.audienceOverride == nil ? "✓" : nil
                ) { coordinator.selectComposerAudience(nil, for: state) },
                PopoverMenuItem(
                    title: "Internal", icon: .blank,
                    detail: state.audienceOverride == .internalRecipients ? "✓" : nil
                ) { coordinator.selectComposerAudience(.internalRecipients, for: state) },
                PopoverMenuItem(
                    title: "External", icon: .blank,
                    detail: state.audienceOverride == .externalRecipients ? "✓" : nil
                ) { coordinator.selectComposerAudience(.externalRecipients, for: state) }
            ]
        case .model:
            let items = coordinator.composerModelGroups.flatMap { group in
                group.options.enumerated().map { index, option in
                    PopoverMenuItem(title: option.title, icon: option.menuIcon,
                        sectionTitle: index == 0 ? group.title : nil,
                        detail: coordinator.composerModel.map { option.matches($0) } == true ? "✓" : nil
                    ) { coordinator.selectComposerModel(option) }
                }
            }
            return items.isEmpty
                ? [PopoverMenuItem(title: "No models available. Check AI Settings.", icon: .blank,
                    isEnabled: false) {}] : items
        case .reasoning:
            return coordinator.composerEfforts.map { effort in
                PopoverMenuItem(title: effort.title, icon: .blank,
                    detail: coordinator.composerModel?.effort == effort.id ? "✓" : nil
                ) { coordinator.selectComposerEffort(effort) }
            }
        default: return []
        }
    }

    static func handleKey(
        _ event: NSEvent, state: QuickActionPanelState,
        coordinator: QuickActionCoordinator) -> Bool?
    {
        guard state.accessory != nil else { return nil }
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            state.accessory = nil
            return true
        }
        let items = menuItems(state: state, coordinator: coordinator)
        if key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            if !event.modifierFlags.contains(.command), items.indices.contains(state.accessorySelection),
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
                    ? "No Outlook email context was captured. Focus the reply body in Outlook and reopen Composer."
                    : "Outlook context is off. Enable Use Outlook context for Composer in Quick Actions settings."
            }
            return "Snapshot from when Composer opened. Only the captured text below accompanies your request.\n\n"
                + "Recipients: \(context.recipient ?? "Not captured")\n\n"
                + "Subject: \(context.subject ?? "Not captured")\n\n"
                + "Recent messages:\n\(context.recentThread ?? "No quoted messages captured. This may be a new email.")"
        }
    }
}

struct ComposerModelControls: View {
    @Environment(QuickActionCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics
    @Bindable var state: QuickActionPanelState

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            control(coordinator.composerModelTitle, label: "Composer model", accessory: .model)
            if !coordinator.composerEfforts.isEmpty {
                control(coordinator.composerEffortTitle, label: "Reasoning level", accessory: .reasoning)
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

    private func control(
        _ title: String, label: String, accessory: QuickActionPanelState.Accessory
    ) -> some View {
        Button { toggle(accessory) } label: {
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
    }

    private func toggle(_ accessory: QuickActionPanelState.Accessory) {
        if accessory == .model { coordinator.prepareComposerModels() }
        state.accessory = state.accessory == accessory ? nil : accessory
        state.accessorySelection = ComposerToolbar.menuItems(state: state, coordinator: coordinator)
            .firstIndex { $0.detail == "✓" } ?? 0
    }
}
