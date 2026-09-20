import AppKit
import Observation

/// The single funnel for every Quick Action, however it was started.
@MainActor
@Observable
final class QuickActionCoordinator {
    private let settings: AppSettings
    private let store: QuickActionSettingsStore
    private let history: RewriteHistoryStore
    private let customActions: CustomQuickActionStore
    private let injector: TextInjector
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private let panels = QuickActionPanelController()
    private unowned let core: AppCore

    private static let launcherCommands = Set(BuiltInQuickAction.allCases.map(CommandID.init))

    var composerModel: AIModelSelection? {
        store.model(for: .rewrite) ?? core.aiSettings.defaultModel
    }

    var composerModelGroups: [AIModelOptionGroup] {
        AIModelOption.availableGroups(
            settings: core.aiSettings, subscription: core.chatGPTSubscription,
            installedAI: core.installedAI)
    }

    var composerModelTitle: String {
        guard let selected = composerModel else { return "Choose model" }
        return composerModelGroups.flatMap(\.options).first { $0.matches(selected) }?.title
            ?? selected.model
    }

    var composerEfforts: [ChatGPTSubscription.Effort] {
        AIModelOption.efforts(
            for: composerModel, settings: core.aiSettings, subscription: core.chatGPTSubscription,
            installedAI: core.installedAI)
    }

    var composerEffortTitle: String {
        composerEfforts.first { $0.id == composerModel?.effort }?.title ?? "Default reasoning"
    }

    var usesOutlookContext: Bool { store.settings.usesOutlookContextForRewrite }

    func detectedComposerAudience(for state: QuickActionPanelState) -> ComposerAudience {
        state.detectedComposerAudience(internalDomains: store.settings.internalEmailDomains)
    }

    func composerAudience(for state: QuickActionPanelState) -> ComposerAudience {
        state.composerAudience(internalDomains: store.settings.internalEmailDomains)
    }

    func selectComposerAudience(
        _ audience: ComposerAudience?, for state: QuickActionPanelState
    ) {
        guard !state.isRunning else { return }
        state.audienceOverride = audience
        saveHistory(state)
    }

    func prepareComposerModels() {
        core.applyInstalledAILifecycle()
    }

    func selectComposerModel(_ option: AIModelOption) {
        guard running == nil, composerModelGroups.flatMap(\.options).contains(where: { $0.id == option.id })
        else { return }
        store.setModelOverride(
            AIModelOption.withDefaultEffort(
                option.selection, settings: core.aiSettings, subscription: core.chatGPTSubscription,
                installedAI: core.installedAI), for: .rewrite)
    }

    func selectComposerEffort(_ effort: ChatGPTSubscription.Effort) {
        guard running == nil, let selected = composerModel,
            composerEfforts.contains(where: { $0.id == effort.id }) else { return }
        store.setModelOverride(selected.withEffort(effort.id), for: .rewrite)
    }

    /// One at a time: two runs race for one selection, and the second overwrites the first's work.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeComposer: QuickActionPanelState?
    @ObservationIgnored private var composerApp: NSRunningApplication?
    @ObservationIgnored private var composerTarget: ComposerTextTarget?
    @ObservationIgnored private var composerFrame: CGRect?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(
        settings: AppSettings, store: QuickActionSettingsStore, history: RewriteHistoryStore,
        customActions: CustomQuickActionStore, injector: TextInjector,
        appIndex: AppIndex, hotKeys: HotKeyManager, favorites: FavoritesStore,
        visibility: VisibilityStore, ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.history = history
        self.customActions = customActions
        self.injector = injector
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Launcher rows come and go with the switch; the Carbon bindings stay registered.
    func applyEnabled() {
        appIndex.setCommandsVisible(Self.launcherCommands, settings.quickActionsEnabled)
        applyCustomQuickActionsPresence()
        guard settings.quickActionsEnabled else {
            cancel()
            core.applyInstalledAILifecycle()
            return
        }
        core.applyInstalledAILifecycle()
        store.resolveModel(
            appleIntelligenceAvailable: core.aiSettings.isAppleIntelligenceAvailable(),
            fallback: core.aiSettings.defaultModel)
        loadLanguages()
    }

    /// Enabling is consent: reading a selection and typing over it both need Accessibility.
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.quickActionsEnabled else { return }
        guard enabled else {
            settings.quickActionsEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable Quick Actions?",
                    message:
                        "Tinycast needs Accessibility permission to read selected text or the "
                        + "active text field in other apps, then insert a result. Nothing is read "
                        + "until you press a shortcut.",
                    symbol: "wand.and.sparkles", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.quickActionsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    func setOutlookContextEnabled(_ enabled: Bool) {
        guard enabled != store.settings.usesOutlookContextForRewrite else { return }
        guard enabled else {
            store.settings.usesOutlookContextForRewrite = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Use Outlook Context?",
                    message:
                        "When Composer runs in Outlook, Tinycast will send the recipients, subject, "
                        + "and two newest quoted messages to the selected Quick Actions model "
                        + "along with your selected draft or writing request. Nothing is read until "
                        + "you run Composer.",
                    symbol: "envelope.badge", confirmTitle: "Enable", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            store.settings.usesOutlookContextForRewrite = true
        }
    }

    func applyCustomQuickActionsPresence() {
        appIndex.setCustomQuickActions(
            settings.quickActionsEnabled ? customActions.actions : [])
    }

    // MARK: - The reader's own actions

    /// The route is stored only once the record is on disk, so a refused save leaves neither behind.
    func addCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        let action = try customActions.add(draft)
        store.setModelOverride(model, for: .custom(action))
    }

    func updateCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        try customActions.update(draft)
        store.setModelOverride(model, for: .custom(draft))
    }

    func setPreviewsResult(_ previews: Bool, id: UUID) {
        do {
            try customActions.setPreviewsResult(previews, id: id)
        } catch {
            report(error)
        }
    }

    func deleteCustomQuickAction(id: UUID) async {
        guard let action = customActions.action(id: id) else { return }
        guard
            await core.confirm(
                title: "Delete “\(action.name)”?",
                message: "Its instructions, shortcut and learned ranking go with it.",
                symbol: action.symbol, confirmTitle: "Delete")
        else { return }
        // Unwound only once the row is gone, so a kept record never loses its shortcut.
        do {
            guard let removed = try customActions.remove(id: id) else { return }
            removeCustomQuickActionReferences(removed)
        } catch {
            report(error)
        }
    }

    private func report(_ error: CustomQuickActionError) {
        Task {
            await core.showNotice(
                title: "Couldn’t Save the Change", message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    private func removeCustomQuickActionReferences(_ action: CustomQuickAction) {
        let hotKeyAction = HotKeyAction.quickAction(id: action.id)
        if hotKeys.recordingAction == hotKeyAction { hotKeys.recordingAction = nil }
        hotKeys.setBinding(nil, for: hotKeyAction)
        store.setModelOverride(nil, for: .custom(action))
        favorites.remove(keys: [action.entryID])
        visibility.removeItemKeys([action.entryID])
        aliases.removeKeys([action.entryID])
        ranking.reset(itemKey: action.entryID)
    }

    func run(id: UUID) {
        guard let action = customActions.action(id: id) else { return }
        run(.custom(action))
    }

    func run(_ action: QuickAction) {
        guard settings.quickActionsEnabled else { return }
        if running != nil {
            if action == .rewrite, let activeComposer, activeComposer.isRunning {
                present(activeComposer, target: composerApp)
            } else {
                core.showMessage("A Quick Action is still running")
            }
            return
        }
        let target = paletteCoordinator.targetApp
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        start { [weak self] in await self?.begin(action, target: target) }
    }

    func cancel() {
        stopComposer()
        generation += 1
        running?.cancel()
        running = nil
        panels.dismiss()
        activeComposer = nil
        composerTarget = nil
        composerFrame = nil
        composerApp = nil
    }

    private func stopComposer() {
        guard let activeComposer, activeComposer.isRunning else { return }
        generation += 1
        running?.cancel()
        running = nil
        activeComposer.fail("Stopped. You can edit and send your request again.")
        saveHistory(activeComposer)
    }

    /// The generation stops a superseded task from clearing the newer handle as it finishes.
    private func start(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        running?.cancel()
        running = Task { [weak self] in
            await work()
            guard let self, mine == self.generation else { return }
            self.running = nil
        }
    }

    private func begin(_ action: QuickAction, target: NSRunningApplication?) async {
        if action == .rewrite { history.prune() }
        let input: QuickActionRunner.Input
        do {
            input = try await QuickActionRunner.input(
                for: action, in: target, using: injector)
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        guard !Task.isCancelled else { return }
        let capture =
            action == .rewrite && store.settings.usesOutlookContextForRewrite
            ? OutlookComposeContextReader.read(in: target)
            : nil
        let context = capture?.context
        composerTarget = capture?.target
        composerFrame = action == .rewrite
            ? ComposerPlacementReader.frame(in: target, editor: capture?.target.editor) : nil
        composerApp = target
        activeComposer = nil
        let selection = switch input {
        case .selection(let text): text
        case .insertionPoint: ""
        }
        if action == .rewrite,
            let record = history.resumableRecord(selection: selection, context: context)
        {
            let state = QuickActionPanelState(
                restoring: record, context: context, targetLanguage: targetLanguage,
                insertsAtCaret: input == .insertionPoint)
            if let textTarget = capture?.target {
                textTarget.restore(record)
                state.draftAnchor = textTarget.anchor
                if let draft = textTarget.draft {
                    state.adoptSourceDraft(draft)
                } else {
                    state.replacementIssue = "Select the draft in Outlook and reopen Composer to replace it."
                }
            } else {
                state.replacementIssue = "Reopen Composer in the Outlook draft before replacing it."
            }
            present(state, target: target)
            if let resumed = state.historyRecord(
                now: state.conversation == record.messages ? record.updatedAt : Date())
            {
                if !history.save(resumed) {
                    core.showMessage("Couldn't save Composer history", tone: .danger)
                }
            }
            return
        }
        let state = QuickActionPanelState(
            action: action, original: selection, context: context,
            targetLanguage: targetLanguage,
            awaitsWritingInstruction: input == .insertionPoint)
        state.draftAnchor = capture?.target.anchor
        if action == .rewrite, store.settings.usesOutlookContextForRewrite,
            OutlookComposeContextReader.isOutlook(target), capture == nil
        {
            state.replacementIssue = "Couldn't capture this Outlook draft. Reopen Composer to try again."
        }
        if input == .insertionPoint {
            present(state, target: target)
            return
        }
        let previews = store.settings.previewsResult(action)
        if previews { present(state, target: target) }
        saveHistory(state)
        await perform(state, target: target, previewing: previews)
    }

    /// A missing permission cannot be fixed from a pill that fades, so it earns a dialog instead.
    private func reportRefusal(_ failure: QuickActionFailure) {
        guard failure.opensAccessibilitySettings else {
            core.showMessage(failure.localizedDescription, tone: .danger)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: "Quick Actions can't read this text field",
                    message:
                        "Tinycast needs Accessibility permission to read the active text field and "
                        + "insert a result. If Tinycast is already listed, switch it off "
                        + "and on again — a rebuilt app keeps a stale entry.",
                    symbol: "wand.and.sparkles", recovery: "Open System Settings")
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    private func perform(
        _ state: QuickActionPanelState, target: NSRunningApplication?, previewing: Bool
    ) async {
        do {
            let text = try await produce(state, previewing: previewing)
            guard !Task.isCancelled else { return }
            state.finish(text)
            saveHistory(state)
            if previewing { return }
            if state.replacementIssue != nil {
                present(state, target: target)
                return
            }
            deliver(text, to: target, action: state.action, textTarget: composerTarget)
        } catch is CancellationError {
            return
        } catch let error as TextTranslator.Failure where error.needsDownload {
            // A HUD cannot say where the download lives, so this has to become a panel.
            if !previewing { present(state, target: target) }
            state.requireLanguageDownload()
        } catch {
            guard !Task.isCancelled else { return }
            report(error, state: state, previewing: previewing)
            saveHistory(state)
        }
    }

    /// Without a panel there is nothing on screen saying the model is working, so the pill says it.
    private func produce(
        _ state: QuickActionPanelState, previewing: Bool
    ) async throws -> String {
        guard !previewing else { return try await generate(state, streaming: true) }
        core.showProgress(state.action.progressTitle)
        defer { core.hideProgress() }
        return try await generate(state, streaming: false)
    }

    private func generate(
        _ state: QuickActionPanelState, streaming: Bool
    ) async throws -> String {
        if state.action.usesTranslationFramework {
            return try await TextTranslator.translate(state.original, to: state.targetLanguage)
        }
        let provider = try core.quickActionProvider(for: state.action)
        let requestGeneration = generation
        return try await QuickActionRunner.run(
            state.action, selection: state.original, using: provider,
            instructionOverride: store.settings.instructionOverride(for: state.action),
            context: state.context,
            selectionIsWritingInstruction: state.originalIsWritingInstruction,
            audience: state.action == .rewrite ? composerAudience(for: state) : nil,
            onDelta: { delta in
                guard streaming, requestGeneration == self.generation, state.isRunning else { return }
                state.append(delta)
            })
    }

    /// A replacement that never lands would otherwise lose the reply, so the clipboard keeps it.
    private func deliver(
        _ text: String, to target: NSRunningApplication?, action: QuickAction,
        textTarget: ComposerTextTarget? = nil
    ) {
        let deliveredText = QuickActionOutput.preparedForDelivery(
            text, action: action, toOutlook: OutlookComposeContextReader.isOutlook(target))
        injector.replaceSelection(
            with: deliveredText, in: target,
            prepareTarget: { textTarget?.prepare(in: target) ?? true },
            onDelivered: { [weak self] in self?.core.showMessage("\(action.title) applied") },
            onFailed: { [weak self] in
                Paster.copyPlainText(deliveredText)
                self?.core.showMessage(
                    "\(action.title) couldn't replace the selection — copied instead",
                    tone: .danger)
            })
    }

    /// A failure the reader cannot see is a hotkey that silently did nothing.
    private func report(_ error: Error, state: QuickActionPanelState, previewing: Bool) {
        guard previewing else {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        state.fail(error.localizedDescription)
    }

    private func present(_ state: QuickActionPanelState, target: NSRunningApplication?) {
        if state.action == .rewrite {
            activeComposer = state
            composerApp = target
        }
        let textTarget = composerTarget
        panels.present(
            state,
            coordinator: self,
            history: history,
            palette: core.palette,
            metrics: settings.interfaceSize.metrics,
            languages: offeredLanguages,
            sourceFrame: state.action == .rewrite ? composerFrame : nil,
            onRetranslate: { [weak self] language in
                state.targetLanguage = language
                self?.rerun(state, target: target)
            },
            onRefine: { [weak self] in
                self?.refine(state, target: target)
            },
            onStop: { [weak self] in self?.stopComposer() },
            onInstructionChange: { [weak self] in self?.schedulePendingSave(state) },
            onDismiss: { [weak self] in
                self?.savePendingInstruction(state)
            },
            onDeleteHistory: { [weak self] id in
                self?.deleteHistory(id, currentID: state.historyID) ?? false
            },
            onReplace: { [weak self] text in
                self?.deliver(text, to: target, action: state.action, textTarget: textTarget)
            })
    }

    private func deleteHistory(_ id: UUID, currentID: UUID) -> Bool {
        guard history.remove(id: id) else {
            core.showMessage("Couldn't delete the Composer conversation", tone: .danger)
            return false
        }
        if id == currentID {
            pendingSave?.cancel()
            generation += 1
            running?.cancel()
            running = nil
            panels.dismiss(preservingDraft: false)
            activeComposer = nil
            composerTarget = nil
            composerFrame = nil
            composerApp = nil
        }
        return true
    }

    private func rerun(_ state: QuickActionPanelState, target: NSRunningApplication?) {
        state.restart()
        start { [weak self] in await self?.perform(state, target: target, previewing: true) }
    }

    private func refine(
        _ state: QuickActionPanelState, target: NSRunningApplication?
    ) {
        if state.needsInitialRequest, state.originalIsWritingInstruction {
            guard state.beginInitialRewrite() != nil else { return }
            saveHistory(state)
            start { [weak self] in
                await self?.perform(state, target: target, previewing: true)
            }
            return
        }
        guard let input = state.beginRefinement() else { return }
        saveHistory(state)
        start { [weak self] in
            await self?.performRefinement(
                state, draft: input.draft.isEmpty ? state.original : input.draft,
                messages: input.messages)
        }
    }

    private func performRefinement(
        _ state: QuickActionPanelState, draft: String, messages: [AIMessage]
    ) async {
        do {
            let provider = try core.quickActionProvider(for: .rewrite)
            let requestGeneration = generation
            let text = try await QuickActionRunner.refineRewrite(
                original: state.original, latestDraft: draft, messages: messages,
                context: state.context, using: provider,
                instructionOverride: store.settings.instructionOverride(
                    for: BuiltInQuickAction.rewrite),
                originalIsWritingInstruction: state.originalIsWritingInstruction,
                audience: composerAudience(for: state),
                onDelta: {
                    guard requestGeneration == self.generation, state.isRunning else { return }
                    state.append($0)
                })
            guard !Task.isCancelled else { return }
            state.finish(text)
            saveHistory(state)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state.fail(error.localizedDescription)
            saveHistory(state)
        }
    }

    private func saveHistory(_ state: QuickActionPanelState) {
        guard state.action == .rewrite,
            let record = state.historyRecord()
        else { return }
        if !history.save(record) {
            core.showMessage("Couldn't save Composer history", tone: .danger)
        }
    }

    private func savePendingInstruction(_ state: QuickActionPanelState) {
        pendingSave?.cancel()
        guard state.action == .rewrite else { return }
        guard !state.isRunning else { return }
        let instruction = state.refinementInstruction.isEmpty
            ? nil : state.refinementInstruction
        let saved: Bool
        if history.records.contains(where: { $0.id == state.historyID }) {
            saved = history.savePendingInstruction(instruction, id: state.historyID)
        } else if instruction != nil, let record = state.historyRecord() {
            saved = history.save(record)
        } else {
            saved = true
        }
        if !saved {
            core.showMessage("Couldn't save the unfinished Composer request", tone: .danger)
        }
    }

    private func schedulePendingSave(_ state: QuickActionPanelState) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.savePendingInstruction(state)
        }
    }

    private var targetLanguage: Locale.Language {
        let stored = store.settings.targetLanguage
        guard !stored.isEmpty else { return Locale.current.language }
        return Locale.Language(identifier: stored)
    }

    /// Observed, not ignored: it arrives after the pane has painted, and the picker has to notice.
    private(set) var offeredLanguages: [Locale.Language] = []
    @ObservationIgnored private var languageLoad: Task<Void, Never>?

    func loadLanguages() {
        guard offeredLanguages.isEmpty, languageLoad == nil else { return }
        languageLoad = Task { [weak self] in
            let languages = await TextTranslator.supportedLanguages()
            self?.offeredLanguages = languages
        }
    }
}

extension TextTranslator.Failure {
    var needsDownload: Bool {
        if case .notInstalled = self { return true }
        return false
    }
}
