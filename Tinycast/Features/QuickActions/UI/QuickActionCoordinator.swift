import AppKit
import Observation

/// What stands between Composer and the signed-in Claude CLI.
enum ComposerClaudeSetup: Equatable {
    case turnOn
    case checking
    case signIn
    case install
    case failed(String)
}

/// The single funnel for every Quick Action, however it was started.
@MainActor
@Observable
final class QuickActionCoordinator {
    private struct NoteSelection {
        let editor: NoteTextView
        let document: NoteEditorInput
        let range: NSRange
        let text: String
    }
    private struct Target {
        var app: NSRunningApplication?
        var note: NoteSelection?
        var text: ComposerTextTarget?
        var frame: CGRect?
    }

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
        ComposerModelPolicy.resolve(
            store.model(for: .rewrite) ?? core.aiSettings.defaultModel,
            catalog: core.chatGPTSubscription.models)
    }

    var composerModelGroups: [AIModelOptionGroup] {
        AIModelOption.availableGroups(
            settings: core.aiSettings, subscription: core.chatGPTSubscription,
            installedAI: core.installedAI)
    }

    var composerClaudeSetup: ComposerClaudeSetup? {
        guard core.aiSettings.enabledInstalledProviders.contains(.claude) else { return .turnOn }
        switch core.installedAI.status(for: .claude).phase {
        case .ready: return nil
        case .idle, .checking: return .checking
        case .signInRequired: return .signIn
        case .notInstalled: return .install
        case .failed(let message): return .failed(message)
        }
    }

    func performComposerClaudeSetup(_ setup: ComposerClaudeSetup) {
        switch setup {
        case .turnOn:
            core.aiSettings.setInstalledProviderEnabled(true, for: .claude)
            core.applyInstalledAILifecycle()
        case .signIn:
            let command = InstalledAIKind.claude.signInCommand
            guard Paster.copyPlainText(command) else { return }
            core.showMessage("Copied \(command). Run it in Terminal, then reopen this menu.")
        case .install:
            NSWorkspace.shared.open(InstalledAIKind.claude.installURL)
        case .checking, .failed:
            break
        }
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

    var composerSeesScreenshots: Bool {
        switch composerModel {
        case .claude?, .codex?: return true
        case .appleIntelligence?, .grok?, .cursor?, nil: return false
        case .openCode(let model, _)?:
            return core.installedAI.status(for: .openCode).models.contains { $0.id == model && $0.acceptsImages }
        case .api(let connection, let model, _)?:
            return core.aiSettings.connection(id: connection)?.capabilities(for: model).images == true
        }
    }

    @ObservationIgnored private var screenshotRead: Task<Void, Never>?
    @ObservationIgnored private var screenshotReadID = UUID()

    func pasteComposerScreenshot(into state: QuickActionPanelState, from board: NSPasteboard) -> Bool {
        guard state === activeComposer, state.action == .rewrite, state.isViewingActive,
            QuickActionRunner.ScreenshotReader.hasCandidate(on: board)
        else { return false }
        guard !state.isRunning else { return true }
        attachClipboardScreenshot(to: state, from: board)
        return true
    }

    func pasteComposerImageFiles(_ urls: [URL], into state: QuickActionPanelState) -> Bool {
        guard state === activeComposer, !state.isRunning, state.isViewingActive else { return false }
        attachScreenshot(to: state) { try await QuickActionRunner.ScreenshotReader.readFiles(urls) }
        return true
    }

    func attachClipboardScreenshot(to state: QuickActionPanelState, from board: NSPasteboard = .general) {
        let count = board.changeCount
        attachScreenshot(to: state) {
            guard board.changeCount == count else { throw QuickActionRunner.ScreenshotReader.Failure.clipboardChanged }
            return try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: AppPaths.caches())
        }
    }

    private func attachScreenshot(
        to state: QuickActionPanelState,
        read: @escaping @MainActor () async throws -> RewriteConversationMessage.Screenshot,
        onAttached: (@MainActor () -> Void)? = nil
    ) {
        guard state === activeComposer, !state.isRunning, state.isViewingActive else { return }
        screenshotRead?.cancel()
        let id = UUID()
        screenshotReadID = id
        state.isAttachingScreenshot = true
        screenshotRead = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await read()
                guard !Task.isCancelled, screenshotReadID == id, activeComposer === state else { return }
                state.setScreenshot(image)
                saveHistory(state)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, screenshotReadID == id, activeComposer === state else { return }
                state.screenshotIssue = error.localizedDescription
            }
            guard screenshotReadID == id else { return }
            state.isAttachingScreenshot = false
            screenshotRead = nil
            if state.screenshotIssue == nil { onAttached?() }
        }
    }

    func removeComposerScreenshot(from state: QuickActionPanelState) {
        guard state === activeComposer, !state.isRunning, state.isViewingActive else { return }
        screenshotReadID = UUID()
        screenshotRead?.cancel()
        screenshotRead = nil
        state.isAttachingScreenshot = false
        state.setScreenshot(nil)
        saveHistory(state)
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
        guard !state.isRunning, state.isViewingActive, state.audienceOverride != audience
        else { return }
        state.audienceOverride = audience
        saveHistory(state)
    }

    /// `ensure` probes only an idle provider, so a sign-in finished in Terminal needs this.
    func prepareComposerModels() {
        core.applyInstalledAILifecycle()
        switch composerClaudeSetup {
        case .signIn, .install, .failed: core.installedAI.refresh(kind: .claude)
        case .turnOn, .checking, nil: break
        }
    }

    func selectComposerModel(_ option: AIModelOption) {
        let offered = composerModelGroups.flatMap(\.options).contains { $0.id == option.id }
        guard running == nil, offered else { return }
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
    /// The run that is only waiting on Keychain; any newer run or a halt makes this stale.
    @ObservationIgnored private var keychainWaitGeneration: Int?
    private var awaitingKeychain: Bool { keychainWaitGeneration == generation }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeComposer: QuickActionPanelState?
    @ObservationIgnored private var composerApp: Target?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var progressOwner: Int?
    @ObservationIgnored private var reportedHistoryFailure = false

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
        NSApp.activate()
        Task {
            guard
                await core.confirm(
                    title: String(localized: "Enable Quick Actions?"),
                    message: String(
                        localized: """
                            Tinycast needs Accessibility permission to read selected text or the \
                            active text field in other apps, then insert a result. Nothing is read \
                            until you press a shortcut.
                            """),
                    symbol: "wand.and.sparkles", confirmTitle: String(localized: "Continue"),
                    tone: .neutral,
                    confirmRole: .standard)
            else { return }
            guard !settings.quickActionsEnabled else { return }
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
        NSApp.activate()
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
            guard !store.settings.usesOutlookContextForRewrite else { return }
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
                title: String(localized: "Delete “\(action.name)”?"),
                message: String(localized: "Its instructions, shortcut and learned ranking go with it."),
                symbol: action.symbol, confirmTitle: String(localized: "Delete"))
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
                title: String(localized: "Couldn’t Save the Change"), message: error.localizedDescription,
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
        if action == .rewrite, let activeComposer, let composerApp, activeComposer.isRunning,
            running != nil
        {
            present(activeComposer, target: composerApp)
            return
        }
        // Waiting on Keychain is not a run: another action may go ahead and drop that open.
        if running != nil, awaitingKeychain, action == .rewrite {
            core.showMessage(Self.keychainNotice, tone: .neutral)
            return
        }
        if running != nil, !awaitingKeychain {
            core.showMessage("A Quick Action is still running")
            return
        }
        let target = invocationTarget()
        if action == .rewrite, let activeComposer, let composerApp,
            reopens(activeComposer, from: target, toward: composerApp)
        {
            present(activeComposer, target: composerApp)
            return
        }
        if paletteCoordinator.isVisible {
            paletteCoordinator.hidePalette(restoreFocus: target.note != nil)
        }
        start { [weak self] in await self?.begin(action, target: target) }
    }

    /// Read before any await, so focus moving during the ⌘C fallback cannot redirect delivery.
    private func invocationTarget() -> Target {
        var target = Target(app: paletteCoordinator.targetApp)
        let source = paletteCoordinator.isVisible
            ? InjectionTarget.behindPalette(
                ownWindow: paletteCoordinator.previousOwnWindow, app: target.app)
            : InjectionTarget.current()
        if let editor = source?.ownEditor as? NoteTextView {
            target.note = NoteSelection(
                editor: editor, document: core.notesCoordinator.editorInput,
                range: editor.selectedRange(), text: editor.injectableSelection)
        } else if let app = target.app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            target.text = ComposerTextTarget.focusedField(in: app)
        }
        return target
    }

    /// The same field and selection, or the same note passage, is the same request as before.
    private func reopens(
        _ state: QuickActionPanelState, from current: Target, toward original: Target
    ) -> Bool {
        guard state.reopensFromSource else { return false }
        if let note = original.note {
            guard let now = current.note else { return false }
            return now.editor === note.editor && now.document == note.document
                && now.range == note.range
        }
        guard let app = original.app, app.processIdentifier == current.app?.processIdentifier,
            state.context != nil || !store.settings.usesOutlookContextForRewrite
                || !OutlookComposeContextReader.isOutlook(app),
            let field = original.text, case .focusedField(let selection) = field.scope,
            let now = current.text, case .focusedField(let nowSelection) = now.scope,
            CFEqual(now.editor, field.editor)
        else { return false }
        return state.reopensFromField(
            selection: selection, pressedSelection: nowSelection,
            characterCount: field.characterCount, pressedCharacterCount: now.characterCount,
            selectedText: { AccessibilityText.selection(in: app) })
    }

    /// Read after the ⌘C fallback's wait, so it counts only from the field the shortcut found.
    private static func outlookCapture(
        in app: NSRunningApplication?, pressedIn field: ComposerTextTarget?
    ) -> OutlookComposeContextReader.Capture? {
        guard let capture = OutlookComposeContextReader.read(in: app) else { return nil }
        guard let field else { return capture }
        guard CFEqual(field.editor, capture.target.editor),
            case .focusedField(let selection) = field.scope,
            selection == nil || selection == capture.target.selectedRange
        else { return nil }
        return capture
    }

    func cancel() {
        halt()
        hideProgress(ownedBy: progressOwner)
        panels.dismiss()
        forgetComposer()
    }

    private func stopComposer() {
        guard activeComposer?.isRunning == true else { return }
        halt()
    }

    private func halt() {
        generation += 1
        running?.cancel()
        running = nil
        guard let activeComposer, activeComposer.isRunning else { return }
        activeComposer.fail("Stopped. You can edit and send your request again.")
        saveHistory(activeComposer)
    }

    private func forgetComposer() {
        screenshotReadID = UUID()
        screenshotRead?.cancel()
        screenshotRead = nil
        activeComposer?.isAttachingScreenshot = false
        activeComposer = nil
        composerApp = nil
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

    private static let keychainNotice =
        "Composer is waiting for Keychain. Allow access to your history."

    private func begin(_ action: QuickAction, target invoked: Target) async {
        var target = invoked
        let previousComposer = action == .rewrite ? activeComposer : nil
        let input: QuickActionRunner.Input
        do {
            if let noteSelection = target.note {
                input = .selection(try QuickActionRunner.accepted(noteSelection.text))
            } else {
                input = try await QuickActionRunner.input(
                    for: action, in: target.app, using: injector)
            }
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        guard !Task.isCancelled else { return }
        if action == .rewrite {
            // After an update this is where Keychain prompts; Composer opens once it is answered.
            let notice = Task { [weak self] in
                // The prompt can open on another Space, and a silent wait looks like a dead hotkey.
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                // An action started meanwhile owns the status line.
                guard let self, awaitingKeychain else { return }
                core.showMessage(Self.keychainNotice, tone: .neutral)
            }
            let waiting = generation
            keychainWaitGeneration = waiting
            await history.loadOnFirstUse()
            if keychainWaitGeneration == waiting { keychainWaitGeneration = nil }
            notice.cancel()
            guard !Task.isCancelled else { return }
            forgetComposer()
        }
        // A note opens over whatever app is frontmost, which must lend it no email context.
        let readsOutlook = action == .rewrite && target.note == nil
            && store.settings.usesOutlookContextForRewrite
        let capture = readsOutlook
            ? Self.outlookCapture(in: target.app, pressedIn: target.text) : nil
        let context = capture?.context
        if let capture { target.text = capture.target }
        if let note = target.note {
            target.frame = note.editor.window?.frame
        } else if action == .rewrite {
            target.frame = ComposerPlacementReader.frame(
                in: target.app, editor: capture?.target.editor)
        }
        let selection = switch input {
        case .selection(let text): text
        case .insertionPoint: ""
        }
        // A match needs captured context, so a resumed record always has its Outlook capture.
        if action == .rewrite,
            let record = history.resumableRecord(selection: selection, context: context),
            let capture
        {
            capture.target.restore(record, insertsAtCaret: input == .insertionPoint)
            let savedDraft = record.draftAnchor?.rangePreservingLineBreaks(
                in: capture.target.body)
            let resumeTarget = QuickActionPanelState.resumeTarget(
                savedDraft: savedDraft, replacementRange: capture.target.replacementRange)
            let state = QuickActionPanelState(
                restoring: record, context: context, targetLanguage: targetLanguage,
                insertsAtCaret: resumeTarget == .insertionPoint
                    || (resumeTarget == .unavailable && input == .insertionPoint))
            if previousComposer?.historyID == record.id {
                state.screenshot = previousComposer?.screenshot
            }
            state.supportsScreenshotDelivery = target.note == nil
            let rewritesSelection = state.resumeSource(
                resumeTarget, text: capture.target.draft, anchor: capture.target.anchor)
            present(state, target: target)
            if rewritesSelection {
                refine(state, target: target)
                return
            }
            if let resumed = state.historyRecord(
                now: state.conversation == record.messages ? record.updatedAt : Date()),
                !history.save(resumed)
            {
                reportHistoryFailure()
            }
            return
        }
        let state = QuickActionPanelState(
            action: action, original: selection, context: context,
            targetLanguage: targetLanguage,
            awaitsWritingInstruction: input == .insertionPoint)
        if action == .rewrite {
            state.supportsScreenshotDelivery = target.note == nil
        }
        state.draftAnchor = capture?.target.anchor
        if readsOutlook, OutlookComposeContextReader.isOutlook(target.app), capture == nil {
            state.replacementIssue =
                "Couldn't capture this Outlook draft. Reopen Composer to try again."
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
        NSApp.activate()
        Task {
            guard
                await core.reportFailure(
                    title: String(localized: "Quick Actions can't read this text field"),
                    message: String(
                        localized: """
                            Tinycast needs Accessibility permission to read the active text field \
                            and insert a result. If Tinycast is already listed, switch it off and \
                            on again — a rebuilt app keeps a stale entry.
                            """),
                    symbol: "wand.and.sparkles", recovery: String(localized: "Open System Settings"))
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    private func perform(
        _ state: QuickActionPanelState, target: Target, previewing: Bool
    ) async {
        do {
            let text = try await produce(state, previewing: previewing)
            guard !Task.isCancelled else { return }
            let finished = state.finish(text)
            saveHistory(state)
            if previewing { return }
            guard finished else {
                core.showMessage(QuickActionPanelState.emptyDraftMessage, tone: .danger)
                return
            }
            if state.replacementIssue != nil {
                present(state, target: target)
                return
            }
            deliver(
                state.output, replacing: state.original, to: target, action: state.action,
                textTarget: target.text,
                insertsAtCaret: state.insertsAtCaret,
                screenshot: state.screenshot, screenshotOffset: state.screenshotOffset)
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
        let owner = generation
        progressOwner = owner
        core.showProgress(
            state.action.progressTitle,
            onCancel: { [weak self] in self?.cancelProgress(ownedBy: owner) })
        defer { hideProgress(ownedBy: owner) }
        return try await generate(state, streaming: false)
    }

    /// The pill stops only its own action, so a dismissed Composer conversation stays reopenable.
    private func cancelProgress(ownedBy owner: Int) {
        guard progressOwner == owner else { return }
        halt()
        hideProgress(ownedBy: owner)
    }

    private func hideProgress(ownedBy owner: Int?) {
        guard let owner, progressOwner == owner else { return }
        progressOwner = nil
        core.hideProgress()
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
            screenshot: composerSeesScreenshots ? state.screenshot : nil, hasScreenshot: state.screenshotAttached,
            onDelta: { delta in
                guard streaming, requestGeneration == self.generation, state.isRunning
                else { return }
                state.append(delta)
            })
    }

    /// A replacement that never lands would otherwise lose the reply, so the clipboard keeps it.
    private func deliver(
        _ text: String, replacing selection: String, to target: Target, action: QuickAction,
        textTarget: ComposerTextTarget? = nil, insertsAtCaret: Bool = false,
        screenshot: RewriteConversationMessage.Screenshot? = nil, screenshotOffset: Int? = nil,
        onDelivered delivered: @escaping @MainActor () -> Void = {}
    ) {
        // A note floats over the frontmost app, so Outlook behind it is not where the text lands.
        let toOutlook = target.note == nil && OutlookComposeContextReader.isOutlook(target.app)
        let marked = screenshot == nil ? text : RewriteConversationMessage.Screenshot.marked(text, offset: screenshotOffset)
        let formatted = QuickActionOutput.preparedForDelivery(
            marked, action: action, toOutlook: toOutlook,
            insertsAtCaret: insertsAtCaret,
            boundaries: textTarget?.textBoundaries, replacing: insertsAtCaret ? "" : selection)
        let parsed = screenshot == nil ? (text: formatted, offset: formatted.utf16.count)
            : RewriteConversationMessage.Screenshot.split(formatted)
        let deliveredText = parsed.text
        if let note = target.note {
            guard core.notesCoordinator.editorInput == note.document,
                note.editor.window?.isVisible == true,
                note.editor.replaceUnchangedSelection(
                    with: deliveredText, source: note.document.source, range: note.range)
            else {
                Paster.copyPlainText(deliveredText)
                core.showMessage("The note changed. Draft copied instead.", tone: .danger)
                return
            }
            delivered()
            core.showMessage("\(action.title) applied")
            return
        }
        let verb = insertsAtCaret ? "insert" : "replace"
        let excludesEdges = toOutlook && !insertsAtCaret
            && !QuickActionOutput.carriesEdges(of: selection, in: deliveredText)
        let prepare: @MainActor () -> Bool = {
            textTarget?.prepare(in: target.app, excludingSelectionEdges: excludesEdges) ?? true
        }
        let success: @MainActor () -> Void = { [weak self] in
            delivered()
            self?.core.showMessage("\(action.title) applied")
        }
        let failure: @MainActor () -> Void = { [weak self] in
            textTarget?.restoreSelection(in: target.app)
            if screenshot == nil { Paster.copyPlainText(deliveredText) }
            let issue = screenshot == nil ? textTarget?.preparationFailure?.message : nil
            let fallback = screenshot == nil
                ? "\(action.title) couldn't \(verb) the draft. Draft copied."
                : String(localized: "Couldn't paste the screenshot draft. Reopen Composer to retry; clipboard preserved.")
            self?.core.showMessage(issue
                ?? fallback, tone: .danger)
        }
        if let screenshot {
            injector.replaceSelection(with: {
                try await QuickActionRunner.ScreenshotDelivery.item(
                    text: deliveredText, offset: parsed.offset, image: screenshot)
            }, in: target.app, prepareTarget: prepare, onDelivered: success, onFailed: failure)
        } else {
            injector.replaceSelection(with: deliveredText, in: target.app, prepareTarget: prepare,
                onDelivered: success, onFailed: failure)
        }
    }

    /// A failure the reader cannot see is a hotkey that silently did nothing.
    private func report(_ error: Error, state: QuickActionPanelState, previewing: Bool) {
        guard previewing else {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        state.fail(error.localizedDescription)
    }

    private func present(_ state: QuickActionPanelState, target: Target) {
        // A reopened conversation skips the resume lookup, which is where expired rows go.
        history.prune()
        track(state, target: target)
        state.viewedHistoryID = nil
        panels.present(
            state,
            coordinator: self,
            history: history,
            palette: core.palette,
            metrics: settings.interfaceSize.metrics,
            languages: offeredLanguages,
            sourceFrame: target.frame,
            onRetranslate: { [weak self] language in
                guard let self, mayRun(state) else { return }
                state.targetLanguage = language
                rerun(state, target: target)
            },
            onRefine: { [weak self] in
                guard let self, mayRun(state) else { return }
                refine(state, target: target)
            },
            onStop: { [weak self] in self?.stopComposer() },
            onInstructionChange: { [weak self] in self?.schedulePendingSave(state) },
            onDismiss: { [weak self] in self?.savePendingInstruction(state) },
            onReplace: { [weak self] text in
                guard let self else { return }
                // Forgotten only once it lands: after a failure the same press reopens it to retry.
                deliver(
                    text, replacing: state.original, to: target, action: state.action,
                    textTarget: target.text,
                    insertsAtCaret: state.insertsAtCaret,
                    screenshot: state.screenshot, screenshotOffset: state.screenshotOffset,
                    onDelivered: { [weak self] in
                        guard let self else { return }
                        if state === activeComposer { forgetComposer() }
                        retarget(state, to: target.text)
                    })
            })
    }

    /// A resumed conversation keeps its saved draft boundary until a draft lands somewhere else.
    private func retarget(_ state: QuickActionPanelState, to textTarget: ComposerTextTarget?) {
        guard state.action == .rewrite, let anchor = textTarget?.anchor, anchor != state.draftAnchor
        else { return }
        state.draftAnchor = anchor
        let saved = history.records.first { $0.id == state.historyID }?.updatedAt
        guard let record = state.historyRecord(now: saved ?? Date()) else { return }
        if !history.save(record) { reportHistoryFailure() }
    }

    func deleteComposerConversation(_ id: UUID, from state: QuickActionPanelState) {
        guard history.remove(id: id) else {
            core.showMessage("Couldn't delete the Composer conversation", tone: .danger)
            return
        }
        guard id == state.historyID else { return }
        pendingSave?.cancel()
        forgetComposer()
        halt()
        panels.dismiss(preservingDraft: false)
    }

    /// A panel may restart its own run, never silently cancel another Quick Action's.
    private func mayRun(_ state: QuickActionPanelState) -> Bool {
        guard running != nil, !state.isRunning else { return true }
        core.showMessage("A Quick Action is still running")
        return false
    }

    private func rerun(_ state: QuickActionPanelState, target: Target) {
        track(state, target: target)
        state.restart()
        start { [weak self] in await self?.perform(state, target: target, previewing: true) }
    }

    private func track(_ state: QuickActionPanelState, target: Target) {
        guard state.action == .rewrite else { return }
        activeComposer = state
        composerApp = target
    }

    private func refine(
        _ state: QuickActionPanelState, target: Target
    ) {
        guard !state.isAttachingScreenshot else { return }
        let references = QuickActionRunner.ScreenshotReader.imageReferences(in: state.refinementInstruction)
        if !references.urls.isEmpty {
            state.refinementInstruction = references.text
            attachScreenshot(to: state, read: {
                try await QuickActionRunner.ScreenshotReader.readFiles(references.urls)
            }, onAttached: { [weak self, weak state] in
                guard let self, let state, state.refinementInstruction == references.text,
                    state.isViewingActive, activeComposer === state
                else { return }
                refine(state, target: target)
            })
            return
        }
        track(state, target: target)
        if state.needsInitialRequest, state.originalIsWritingInstruction {
            guard state.beginInitialRewrite() != nil else { return }
            saveHistory(state)
            start { [weak self] in
                await self?.perform(state, target: target, previewing: true)
            }
            return
        }
        if state.retriesOriginalRequest {
            rerun(state, target: target)
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
                screenshot: composerSeesScreenshots ? state.screenshot : nil, hasScreenshot: state.screenshotAttached,
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
        guard history.save(record) else { return reportHistoryFailure() }
        state.hasSavedHistory = true
    }

    /// Autosave runs every 350 ms, so a history that cannot be kept says so only once.
    private func reportHistoryFailure() {
        guard !reportedHistoryFailure else { return }
        reportedHistoryFailure = true
        core.showMessage("Composer history couldn't be saved on this Mac", tone: .danger)
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
        } else if instruction != nil, !state.hasSavedHistory, let record = state.historyRecord() {
            saved = history.save(record)
            state.hasSavedHistory = saved
        } else {
            saved = true
        }
        if !saved { reportHistoryFailure() }
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
