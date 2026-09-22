import SwiftUI

struct QuickActionResultView: View {

    @Environment(\.metrics) private var metrics
    @Bindable var state: QuickActionPanelState
    let history: RewriteHistoryStore
    let languages: [Locale.Language]
    let onRefine: () -> Void
    let onStop: () -> Void
    let onInstructionChange: () -> Void
    let onReplace: () -> Void
    let onCopy: (String) -> Void
    let onDeleteHistory: (UUID) -> Bool
    let onSelectionChange: (String, Bool) -> Void
    let onCancel: () -> Void
    let onRetranslate: (Locale.Language) -> Void
    let onOpenLanguageSettings: () -> Void
    let onHeight: (CGFloat) -> Void
    let onWidth: (CGFloat) -> Void

    @AppStorage(SettingsKey.composerHistoryExpanded) private var historyExpanded = false
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var retainedRewriteHeight: CGFloat = 0
    @State private var followsTranscriptTail = true
    @State private var selectedHistoryID: UUID?
    @State private var historyMenuID: UUID?
    @State private var historyMenuSelection = 0
    @State private var transcriptScrollTask: Task<Void, Never>?
    @FocusState private var refinementFocused: Bool

    private static let transcriptTail = "quick-action-transcript-tail"
    private static let deliberateScroll: CGFloat = 2

    private struct ScrollMark: Equatable {
        var offset: CGFloat
        var atEnd: Bool
    }

    private struct SelectionState: Equatable {
        var text: String
        var isViewingActive: Bool
    }

    /// Explicit overlays, not `safeAreaBar`: that lays its bars over the content instead of inset.
    var body: some View {
        panelContent
            .frame(width: panelWidth, height: panelHeight)
            .background(Theme.Colors.panelScrim)
            .background(VisualEffectView())
            .overlay { historyMenuDismissalLayer }
            .overlay(alignment: .bottomLeading) { historyMenu }
            .overlay {
                if state.accessory != nil {
                    Color.clear.contentShape(Rectangle()).onTapGesture { state.accessory = nil }
                }
            }
            .overlay(alignment: .topTrailing) {
                if state.accessory == .context {
                    ComposerToolbar.AccessoryView(state: state, isViewingActive: isViewingActive,
                        maximumHeight: panelHeight - headerHeight - metrics.spacing.xl)
                        .padding(.top, headerHeight)
                        .padding(.trailing, metrics.spacing.xxl)
                }
            }
            .overlay(alignment: .topLeading) {
                if state.accessory == .audience {
                    ComposerToolbar.AccessoryView(state: state, isViewingActive: isViewingActive,
                        maximumHeight: panelHeight - headerHeight - metrics.spacing.xl)
                        .padding(.top, headerHeight)
                        .padding(.leading, composerContentLeadingInset)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if state.accessory == .model || state.accessory == .reasoning {
                    ComposerToolbar.AccessoryView(state: state, isViewingActive: isViewingActive,
                        maximumHeight: panelHeight - footerHeight - metrics.spacing.xl)
                        .padding(.leading, composerContentLeadingInset)
                        .padding(.bottom, footerHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.radius.dialog, style: .continuous))
            .panelEntrance()
            // Reported, not measured: the frame above is ours, so reading it back would feed itself.
            .onChange(of: panelHeight, initial: true) { _, height in
                if state.action == .rewrite {
                    retainedRewriteHeight = max(retainedRewriteHeight, height)
                }
                onHeight(height)
            }
            .onChange(of: panelWidth, initial: true) { _, width in onWidth(width) }
            .onChange(of: state.phase) {
                refinementFocused = isViewingActive && shouldFocusInstruction
            }
            .onChange(of: selectionState, initial: true) { _, selection in
                onSelectionChange(selection.text, selection.isViewingActive)
            }
            .onAppear {
                selectedHistoryID = state.historyID
                refinementFocused = shouldFocusInstruction
            }
            .onChange(of: state.refinementInstruction) { onInstructionChange() }
    }

    @ViewBuilder
    private var panelContent: some View {
        if state.action == .rewrite, historyExpanded {
            HStack(spacing: 0) {
                QuickActionHistorySidebar(
                    records: historyEntries,
                    selectedID: selectedHistoryID,
                    currentID: state.historyID,
                    height: panelHeight,
                    onSelect: selectHistory,
                    onActions: openHistoryMenu,
                    onCollapse: toggleHistory)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: Theme.Size.hairline)
                resultSurface
            }
        } else {
            resultSurface
        }
    }

    private var resultSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    body(for: state.phase)
                    if state.action == .rewrite {
                        Color.clear
                            .frame(height: metrics.spacing.xxs)
                            .id(Self.transcriptTail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.xxl)
                // A `ScrollView` has no ideal height, so the frame below is set, not merely capped.
                .fixedSize(horizontal: false, vertical: true)
                // Measured before the insets, so `isScrollable` cannot depend on its own answer.
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
                .padding(.top, inset(headerHeight))
                .padding(.bottom, inset(footerHeight))
            }
            .onScrollGeometryChange(for: ScrollMark.self) { geometry in
                ScrollMark(
                    offset: geometry.contentOffset.y,
                    atEnd: geometry.contentOffset.y + geometry.containerSize.height
                        + geometry.contentInsets.top
                        >= geometry.contentSize.height - metrics.spacing.md)
            } action: { old, new in
                if new.atEnd {
                    followsTranscriptTail = true
                } else if new.offset < old.offset - Self.deliberateScroll {
                    followsTranscriptTail = false
                }
            }
            .onChange(of: state.conversation.count) {
                followTranscript(proxy, always: true)
            }
            .onChange(of: state.conversation) {
                followTranscript(proxy, always: false)
            }
            .onChange(of: selectedHistoryID) {
                followsTranscriptTail = true
                scrollToTranscriptTail(proxy)
                refinementFocused = isViewingActive && shouldFocusInstruction
            }
            .onChange(of: state.phase) {
                if state.phase == .running {
                    followsTranscriptTail = true
                    followTranscript(proxy, always: true)
                } else {
                    followTranscript(proxy, always: false)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask(scrollFade)
            .overlay(alignment: .top) { measured(header) { headerHeight = $0 } }
            .overlay(alignment: .bottom) { measured(footer) { footerHeight = $0 } }
        }
        .frame(width: metrics.size.quickActionPanel, height: panelHeight)
    }

    private func measured(_ bar: some View, action: @escaping (CGFloat) -> Void) -> some View {
        bar.onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: action)
    }

    private func followTranscript(_ proxy: ScrollViewProxy, always: Bool) {
        guard state.action == .rewrite, isViewingActive,
            always || followsTranscriptTail
        else { return }
        scrollToTranscriptTail(proxy)
    }

    private func scrollToTranscriptTail(_ proxy: ScrollViewProxy) {
        transcriptScrollTask?.cancel()
        transcriptScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(Self.transcriptTail, anchor: transcriptTailAnchor)
        }
    }

    private var transcriptTailAnchor: UnitPoint {
        guard panelHeight > 0 else { return .bottom }
        let visibleBottom = 1 - inset(footerHeight) / panelHeight
        return UnitPoint(x: 0.5, y: min(max(visibleBottom, 0), 1))
    }

    private var panelWidth: CGFloat {
        metrics.size.quickActionPanel
            + (state.action == .rewrite && historyExpanded
                ? metrics.size.quickActionHistorySidebar + Theme.Size.hairline : 0)
    }

    private var composerContentLeadingInset: CGFloat {
        (historyExpanded ? metrics.size.quickActionHistorySidebar + Theme.Size.hairline : 0)
            + metrics.spacing.xxl
    }

    /// Clears the bar and its ramp, so the first line is opaque until it scrolls into the gradient.
    private func inset(_ bar: CGFloat) -> CGFloat {
        bar + (isScrollable ? metrics.size.quickActionScrollFade : 0)
    }

    /// A mask, not `scrollEdgeEffectStyle`: its material composited to nothing over this vibrancy.
    @ViewBuilder
    private var scrollFade: some View {
        if isScrollable {
            VStack(spacing: 0) {
                // Fully clear behind each bar, or text bleeds around the title and the buttons.
                Color.clear.frame(height: headerHeight)
                ramp(from: .clear, to: .black)
                Color.black
                ramp(from: .black, to: .clear)
                Color.clear.frame(height: footerHeight)
            }
        } else {
            // Dissolving a result that already fits would dim it for nothing.
            Color.black
        }
    }

    private func ramp(from start: Color, to end: Color) -> some View {
        LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
            .frame(height: metrics.size.quickActionScrollFade)
    }

    private var isScrollable: Bool { contentHeight > metrics.size.quickActionPanelBody }

    private var panelHeight: CGFloat {
        let measured = measuredPanelHeight
        guard state.action == .rewrite else { return measured }
        return max(measured, retainedRewriteHeight)
    }

    private var measuredPanelHeight: CGFloat {
        let chrome = headerHeight + footerHeight
        let minimumBody = state.action == .rewrite
            ? metrics.size.quickActionRewriteMinBody
            : metrics.size.quickActionPanelMinBody
        return min(
            max(contentHeight + chrome, chrome + minimumBody),
            chrome + metrics.size.quickActionPanelBody)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
        HStack(spacing: metrics.spacing.md) {
            // Only the title run drags: the handle is an overlay, and would eat the menu's clicks.
            HStack(spacing: metrics.spacing.sm) {
                SymbolImage(name: state.action.symbol, size: metrics.size.quickActionHeaderIcon)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(state.action.title)
                    .font(metrics.typography.panelTitle)
                Spacer(minLength: metrics.spacing.md)
            }
            .windowDraggable(true)
            if state.action == .translate, !languages.isEmpty { languageMenu }
            if state.action == .rewrite, !historyExpanded {
                Button {
                    toggleHistory()
                } label: {
                    Label("Recent drafts", systemImage: "sidebar.left")
                        .font(metrics.typography.rowTrailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.textSecondary)
                .help("Show recent drafts")
                .accessibilityLabel("Show recent drafts")
            }
        }
        if state.action == .rewrite {
            ComposerToolbar(state: state, isViewingActive: isViewingActive)
        }
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.top, metrics.spacing.xl)
        .padding(.bottom, metrics.spacing.lg)
    }

    @ViewBuilder
    private func body(for phase: QuickActionPanelState.Phase) -> some View {
        if state.action == .rewrite {
            conversation(for: phase)
        } else {
            switch phase {
            case .awaitingInstruction:
                EmptyView()
            case .running where state.output.isEmpty:
                HStack(spacing: metrics.spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(Theme.Colors.textSecondary)
                }
                .font(metrics.typography.rowTitle)
            case .running, .finished:
                output
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            case .needsLanguageDownload:
                downloadPrompt
            }
        }
    }

    private func conversation(for phase: QuickActionPanelState.Phase) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            ForEach(displayedConversation) { message in
                ConversationRow(message: message)
            }
            if displayedConversation.isEmpty {
                switch phase {
                case .awaitingInstruction:
                    EmptyView()
                case .running where isViewingActive:
                    ConversationRow(
                        message: .init(role: .assistant, text: "", state: .streaming))
                case .failed(let message) where isViewingActive:
                    ConversationRow(
                        message: .init(role: .assistant, text: message, state: .failed))
                case .running, .finished, .failed, .needsLanguageDownload:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var output: some View {
        let chunks = state.diff
        if !chunks.isEmpty {
            // One `Text` per chunk would break the wrap, so the runs are styled inside one string.
            prose(Text(attributed(chunks)))
        } else if state.action == .summarize {
            MarkdownView(blocks: MarkdownBlock.parse(state.output))
                .textSelection(.enabled)
        } else {
            prose(Text(state.output))
        }
    }

    /// A result is a paragraph to read rather than a row label, so it is led like one.
    private func prose(_ text: Text) -> some View {
        text
            .font(metrics.typography.rowTitle)
            .lineSpacing(metrics.spacing.xs)
            .textSelection(.enabled)
    }

    private func attributed(_ chunks: [TextDiffEngine.Chunk]) -> AttributedString {
        chunks.reduce(into: AttributedString()) { result, chunk in
            switch chunk {
            case .equal(let text):
                result.append(AttributedString(text))
            case .inserted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.success
                result.append(run)
            case .deleted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.destructive
                run.strikethroughStyle = .single
                result.append(run)
            }
        }
    }

    /// System Settings, not `prepareTranslation`: its sheet never appears over this panel.
    private var downloadPrompt: some View {
        let language = TextTranslator.displayName(of: state.targetLanguage)
        return VStack(alignment: .leading, spacing: metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text("\(language) hasn't been downloaded yet.")
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("Click **Translation Languages…** in Language & Region, then download it.")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Button("Open Language & Region", action: onOpenLanguageSettings)
                .buttonStyle(.modalAction(.standard, fillsWidth: false))
        }
    }

    private var languageMenu: some View {
        Menu(TextTranslator.displayName(of: state.targetLanguage)) {
            ForEach(languages, id: \.minimalIdentifier) { language in
                Button(TextTranslator.displayName(of: language)) { onRetranslate(language) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            if isViewingActive, let issue = state.replacementIssue {
                Text(issue)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if state.action == .rewrite, isViewingActive { refinementControls }
            HStack(spacing: metrics.spacing.md) {
                if state.action == .rewrite, isViewingActive {
                    ComposerModelControls(state: state)
                }
                Spacer(minLength: metrics.spacing.md)
                Button("Dismiss", action: onCancel)
                    .buttonStyle(.modalAction(.cancel, fillsWidth: false))
                Button("Copy") { onCopy(displayedOutput) }
                    .buttonStyle(.modalAction(.standard, fillsWidth: false))
                    .disabled(displayedOutput.isEmpty)
                Button(state.deliveryActionTitle, action: onReplace)
                    .buttonStyle(.modalAction(.primary, fillsWidth: false))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!state.canDeliver(isViewingActive: isViewingActive))
            }
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.vertical, metrics.spacing.xl)
    }

    private var refinementControls: some View {
        HStack(spacing: metrics.spacing.md) {
            TextField(
                state.isAwaitingInstruction
                    ? "Describe what you want this email to say, or press Return…"
                    : "Describe another change…",
                text: $state.refinementInstruction,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(metrics.typography.rowTitle)
                .lineLimit(1...3)
                .padding(.horizontal, metrics.spacing.lg)
                .frame(minHeight: metrics.size.barButtonHeight)
                .background(
                    RoundedRectangle(
                        cornerRadius: metrics.radius.menu, style: .continuous
                    ).fill(Theme.Colors.controlSurface))
                .focused($refinementFocused)
                .onSubmit(onRefine)
                .disabled(state.isRunning)
                .accessibilityLabel(
                    state.isAwaitingInstruction
                        ? "Email writing instructions" : "Refinement instructions")
            if state.isRunning {
                Button("Stop", action: onStop)
            } else {
                Button(state.needsInitialRequest && !state.isAwaitingInstruction ? "Retry" : "Send",
                    action: onRefine)
                    .disabled(!state.canRefine)
            }
        }
    }

    private struct ConversationRow: View {
        @Environment(\.metrics) private var metrics
        let message: RewriteConversationMessage

        var body: some View {
            HStack {
                if message.role == .user { Spacer(minLength: metrics.spacing.xxl) }
                content
                if message.role == .assistant { Spacer(minLength: metrics.spacing.xxl) }
            }
        }

        @ViewBuilder private var content: some View {
            if message.state == .streaming, message.text.isEmpty {
                HStack(spacing: metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Revising…")
                }
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, metrics.spacing.sm)
                .padding(.vertical, metrics.spacing.md)
            } else {
                Text(message.text)
                    .font(metrics.typography.rowTitle)
                    .lineSpacing(metrics.spacing.xs)
                    .foregroundStyle(
                        message.role == .assistant && message.state == .failed
                            ? Theme.Colors.destructive : Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(
                        .horizontal,
                        message.role == .user ? metrics.spacing.xl : metrics.spacing.sm)
                    .padding(.vertical, metrics.spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                            .fill(
                                message.role == .user
                                    ? Theme.Colors.controlSurface : Color.clear))
            }
        }
    }

    private var historyEntries: [RewriteHistoryRecord] {
        guard let current = state.historyRecord() else { return history.records }
        return [current] + history.records.filter { $0.id != current.id }
    }

    @ViewBuilder
    private var historyMenuDismissalLayer: some View {
        if historyMenuID != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeHistoryMenu() }
                .onRightClick { closeHistoryMenu() }
        }
    }

    @ViewBuilder
    private var historyMenu: some View {
        if let id = historyMenuID,
            let record = historyEntries.first(where: { $0.id == id })
        {
            let items = [
                PopoverMenuItem(
                    title: "Delete Conversation", systemImage: "trash",
                    isDestructive: true
                ) {
                    deleteHistory(id)
                }
            ]
            PopoverMenu(
                header: record.title, items: items,
                selection: $historyMenuSelection,
                onActivate: { items[$0].action() })
                .padding(metrics.spacing.md)
        }
    }

    private func selectHistory(_ id: UUID) {
        state.accessory = nil
        closeHistoryMenu()
        selectedHistoryID = id
    }

    private func openHistoryMenu(_ id: UUID) {
        state.accessory = nil
        selectedHistoryID = id
        historyMenuSelection = 0
        historyMenuID = id
    }

    private func closeHistoryMenu() {
        historyMenuID = nil
    }

    private func toggleHistory() {
        closeHistoryMenu()
        if historyExpanded { selectedHistoryID = state.historyID }
        historyExpanded.toggle()
    }

    private func deleteHistory(_ id: UUID) {
        let deletingActive = id == state.historyID
        guard onDeleteHistory(id) else { return }
        historyMenuID = nil
        if !deletingActive { selectedHistoryID = state.historyID }
    }

    private var isViewingActive: Bool {
        selectedHistoryID == nil || selectedHistoryID == state.historyID
    }

    private var shouldFocusInstruction: Bool {
        state.needsInitialRequest || state.phase == .finished
    }

    private var displayedConversation: [RewriteConversationMessage] {
        let messages = isViewingActive
            ? state.conversation
            : history.records.first { $0.id == selectedHistoryID }?.messages ?? []
        guard state.action == .rewrite else { return messages }
        return messages.map { message in
            guard message.role == .assistant else { return message }
            var bodyMessage = message
            bodyMessage.text = QuickActionOutput.composerBody(in: message.text)
            return bodyMessage
        }
    }

    private var displayedOutput: String {
        let output = isViewingActive
            ? state.output
            : history.records.first { $0.id == selectedHistoryID }?.latestDraft ?? ""
        return state.action == .rewrite ? QuickActionOutput.composerBody(in: output) : output
    }

    private var selectionState: SelectionState {
        SelectionState(
            text: displayedOutput,
            isViewingActive: isViewingActive)
    }

}
