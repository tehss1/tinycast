# Quick Actions

Act on text in whichever app is frontmost. Four are shipped: Fix Grammar, Composer, Translate and
Summarize, each with its own bindable shortcut **and its own launcher command**, both listed in
**Settings → Quick Actions**. Three go through the AI provider layer; Translate goes to Apple's own
translator. A selected-text result either replaces the selection or arrives in a floating panel, per
action. Composer also accepts an insertion point: its panel collects the first writing request, then
inserts the finished draft at that point.

A **custom Quick Action** is a name, a glyph and a prompt, run through the same provider. It takes a
shortcut and a launcher row like any other.

Quick Actions is the provider layer's second consumer. It shares the provider connections and
selectable Markdown renderer with AI Chat.

## Invariants

- **Off out of the box, and off means the shortcuts do nothing.** `AppSettings.quickActionsEnabled`
  is the flag and `QuickActionCoordinator` is the only place that reads it: no selection is read, no
  provider is built, no panel opens. The four commands leave the launcher's Quick Actions slice
  through `AppIndex.setCommandsVisible`, and the custom ones leave it through
  `AppIndex.setCustomQuickActions`, the way Notes and AI Chat drop theirs. Carbon bindings stay
  registered, so re-enabling restores every shortcut without touching the hotkey layer. The flag
  grants keystroke delivery into other apps, so like `snippetsEnabled` it is excluded from settings
  backups — an import must never arm it.
- **One funnel, whichever way an action started.** A shortcut and a launcher row both land on
  `QuickActionCoordinator.run(_:)`, which captures the target **before** hiding the palette. An
  external app remains the usual target; a selected passage in the Notes editor is captured directly
  from its text view. Hiding there rather than at each caller keeps the two paths identical.
- **Enabling is consent, and it is the only place Accessibility is requested.** The toggle confirms
  through `DialogController` first and then calls `Permissions.ensureAccessibility()`, the pattern
  `SnippetCoordinator.setSnippetsEnabled` established. Everything else — a shortcut press, a
  delivery — uses `isAccessibilityTrusted()` and degrades to a HUD.
- **Tinycast is never an event target.** `QuickActionRunner.input(for:in:using:)` refuses our own
  bundle identifier, and `TextInjector.targetAcceptsInjection` refuses it again before every event post,
  along with anything raised while Secure Event Input is up. Notes is the narrow in-process exception:
  its own editor supplies and replaces a selected passage without Accessibility, clipboard or events.
  A shortcut pressed with Settings frontmost, or in a password field, does nothing and says so.
- **One run at a time.** Two overlapping runs would race for one selection, and the second would
  replace text the first had already changed. `QuickActionCoordinator` holds a single task.
  Pressing Composer's shortcut during generation reopens that conversation, even after dismissal.
  Once settled, it reopens from the field and selection, or the note passage, it came from.
  Stop cancels generation and restores the request for editing. A generation token prevents a
  cancelled task from appending to a later request or clearing its handle. Send or a new language
  in an open panel says another action is running instead of cancelling it.
- **A cut-off reply never replaces anything.** A built-in action's reply budget is estimated from
  the selection's UTF-8 size (three bytes a token, so CJK text gets room too) and capped at 8,192
  tokens; a custom action, a built-in with edited instructions, a draft written from an instruction
  and a refinement get the full 8,192, since their reply can outgrow the selection. Only
  Anthropic requests and the on-device route send the budget (on-device clamps it to its own 1,024); OpenAI-shaped requests send none, so the
  server's own limit applies. A route that stops at a limit says so: Anthropic's `max_tokens`, an
  OpenAI-shaped `length`, or, on macOS 26.4 and later, an on-device reply that re-counts to the
  cap. CLI and subscription routes report no stop reason, so a cut there goes undetected.
  `AIStreamEvent.outputLimitReached` fails the run with "The reply hit the model's length limit",
  so part of a long selection can never overwrite all of it. Only a selection-sized budget adds
  "Select less text"; the others ask for a shorter reply.
- **`Model/` stays Foundation-only.** `quick-action-test` compiles that folder standalone, which is
  what keeps `FoundationModels`, `Translation` and `NaturalLanguage` in `Service/` and `UI/`.
- **Quick Actions route themselves.** `quickActionModel` is a second routing decision, defaulting to
  Apple Intelligence and falling back to chat's model. A shortcut pressed all day should not bill an
  API every time, and that is not a choice chat's default can make on its behalf.
- **An action may override that route, and only by choice.** `quickActionModelOverrides` is keyed by
  `QuickAction.id`, so the built-in four and custom actions share one lookup,
  `QuickActionSettingsStore.model(for:)`. An absent entry follows `quickActionModel`, so nothing
  changes until the reader picks a model in the action's sheet. Translate never takes one.
- **A dead override is dropped, never rerouted.** Repair walks every override beside the shared
  route: a vanished catalog model moves to its command's first model, like the shared route, but a
  removed connection or an unavailable command deletes the entry instead of borrowing chat's model.
  The action then follows the route its pane names, not one the reader never chose for it.
- **Installed providers are ordinary routes.** The model picker reads the same live Codex, Claude, Grok,
  OpenCode and Cursor catalogs as AI Settings. Execution still goes through `AIProviderFactory`, so Quick Actions
  inherit the same installed login, tool restrictions and process cleanup without owning CLI logic.
- **The model picker is the AI picker.** Both panes render `AIModelOption.groupedCatalog`, with the
  same provider sections, model labels and provider-supported reasoning levels. An installed-model
  selection stores its effort in `quickActionModel`, independently of chat's effort. The sheets use the
  same `AIModelSelectionRows`, with **Same as Quick Actions** as the `nil` choice.
- **The reader's own text gets permissive guardrails.** `AppCore.quickActionProvider()` asks for
  `SystemLanguageModel.Guardrails.permissiveContentTransformations`. The default filter is tuned for
  a model writing fresh prose and refuses to transform text somebody already wrote, which is the
  whole feature.
- **Built-in instructions distinguish source text from a writing request.** A selected draft is
  untrusted material to transform, never an instruction to follow. In caret-first Composer, the first
  panel entry is a writing request to follow, with its own composition style rather than selected-text
  rewrite or approximate-length restrictions. Caret-first refinements retain that composition style.
  In both modes, the model returns only the finished body text. Composer appends that body-only rule
  after any custom style prompt. At completion, `QuickActionOutput` removes a leading `Subject:`
  line only when the generation's source did not begin with one. A user-authored subject, including
  a subject-only selection, remains usable. Stored drafts and callers without source provenance
  keep their text; they are never stripped again by guessing who wrote a subject.
  Composer also appends a natural-voice rule that forbids em dashes, stock AI phrasing, inflated
  formality, filler and invented warmth. A narrow output guard repairs model-introduced prose dashes
  and familiar AI boilerplate without paraphrasing the substantive message. Source dashes, line-leading
  sign-offs and bullets, and numeric or word ranges stay intact. If source punctuation cannot be
  matched safely, the guard preserves it. The caret-first instruction still identifies the
  panel entry as the request.
- **Outlook context is narrow and separately consented.** The optional Composer toggle reads the
  current compose window only after the reader runs Composer in Outlook. It adds the To, Cc and Bcc
  recipients, subject and at most the two newest quoted messages to the request, skips the draft signature and
  older history, and captures that snapshot once when the shortcut is pressed. Quoted messages are
  found by their header, in the common languages Outlook writes it in, not English alone. Selected-text Composer
  captures the selected draft boundaries. Caret-first Composer captures the insertion point.
  `ComposerDraftAnchor` stores fingerprints of the surrounding text so later replacements cover the
  draft without duplicating it. Caret-first Insert keeps Outlook's signature boundary untouched,
  including rich content such as a logo, and adds a line break only when none follows the caret.
  A caret at the end of a nonempty line starts a new paragraph instead of joining that line.
  The context is enclosed in paired, collision-free begin/end markers and identified as untrusted
  reference material in the prompt; the writing request or selected text follows the closing marker.
  Every remote Accessibility read has a timeout of at most 100 ms, capped to the shared 750 ms
  deadline beginning with editor capture. Discovery stops when all wanted fields are found, runs for
  at most 250 ms and reserves 350 ms for reading fields. A failed or truncated recipient walk reports
  partial context while retaining readable addresses. The subject is read before walking recipients,
  so a slow or large recipient list cannot exhaust the budget before the subject read. An empty
  subject field reads as no subject, never as its own "Subject" label.
  Its opt-in key is excluded from settings backups, so importing settings cannot widen what Tinycast
  reads or sends.
- **Audience tone follows the whole recipient list.** Composer compares every captured To, Cc and Bcc
  address with the internal domains configured in Quick Actions settings. When every address is an exact
  match or a subdomain, the prompt asks for a relaxed, concise coworker tone. A mixed list, an
  outside address, an unreadable recipient, any unresolved token between recipient separators,
  an interrupted To/Cc/Bcc walk or an empty domain list
  uses the safer polished external tone. Partial recipient captures preserve known addresses and
  carry an explicit unavailable-recipient notice, so automatic tone remains External when the
  conversation is reopened. The footer names the effective choice, marks a manual choice and its menu
  can override it for one conversation; that override follows the conversation through its seven-day
  history. The configured domains are excluded from settings backups because they identify an
  organization and change model behavior.
- **Composer history stays local for seven days.** `RewriteHistoryStore` writes transcripts and requests
  to `rewrite-history.sealed` under the bundle-specific Application Support directory, encrypted with
  AES-GCM under a key `RewriteHistoryKey` keeps in Keychain. When Keychain cannot supply the key the
  history is neither read nor written, and a new key is made only when none exists. Key creation
  never replaces an existing key, including one created by another instance at the same time, and a
  malformed existing Keychain value is preserved rather than replaced. Launching never accesses
  Keychain; the first Composer open reads the key and the history. A self-signed build's Keychain
  access is tied to that exact build, so after every update macOS prompts again, and that prompt
  belongs to the first Composer rather than to the update. Keychain is asked away from the main
  thread, so the app stays responsive while it waits, and Composer opens once the prompt is
  answered; after a second of waiting a message says so, since the prompt can open on another
  Space. A prompt that is missed, times out or is denied is asked again on the next Composer open:
  without the key nothing was read or written, so a key that arrives later is still safe. The old plaintext `rewrite-history.json` is deleted at launch without being read; it is
  not migrated. Opening Composer, saving a transcript or the calendar day changing removes records
  whose latest revision is older than seven days. The file is readable only by its owner and
  excluded from backups. Saves stage the encrypted file with owner-only permissions and backup exclusion before
  atomically replacing the destination, so a failed save leaves the previous file intact. An
  unexpired file that cannot be read or authenticated is preserved and blocks writes, so an
  unexpected key cannot replace unread history with an empty list. Inside an authenticated file,
  individual malformed records are skipped rather than discarding the rest.
  A file last written more than seven days ago is deleted at launch without its key, since every
  save rewrites it. Running Composer again on the same Outlook email restores its transcript. When
  no rewrite is pending, a press targeting its saved draft or an outside caret restores the latest
  completed draft without another model request; selecting different text starts a rewrite in that
  conversation. Selecting the text it last rewrote again restores that rewrite, and an unsent typed
  request stays in the field to send instead of the automatic one. A newer selection supersedes one
  still awaiting its rewrite, so only the newest reaches the model.
  Tinycast stores context and individual-message fingerprints
  for matching, not a second copy of the quoted email thread. The context identity uses the subject
  and quoted thread, or the native editor identity when no thread exists; recipient order and
  completeness do not affect it. Each record also remembers its Outlook editor, and that editor's own
  conversation wins over any other, even after its subject changes. In a reply it needs the same
  snapshot or a shared quoted message. In a new email it is refused only when both fully captured
  recipient lists share no address, because Outlook can hand a new email a closed editor's identity.
  Another editor continues a drafted conversation when its quote shares a message and the subject,
  so a new reply that changes the snapshot stays in the conversation, but never when both fully
  captured recipient lists share no address. On the same snapshot, such as a reopened draft, any
  difference between those lists also refuses it unless the selection is its latest draft, so a
  private reply and a reply-all to one message stay separate, while a reopened draft that gained a Cc
  resumes when its draft is selected. Among matches, a conversation addressed to exactly the same
  fully captured recipients comes first, then the one with the most messages, then the latest
  revision. If older records contain duplicates for the same editor, the first matching run keeps
  that preferred transcript and removes the other rows. A
  row found only through a shared quote, or owned by another editor, is never removed. Reopening does
  not extend retention because only a revision updates the record's
  timestamp. Input autosaves after 350 milliseconds and flushes when the panel closes.
  Typing does not extend retention. In-flight requests remain recoverable until generation succeeds.
  New emails without quoted history match only by the native Outlook editor identity.
  Recreating that editor, including restarting Outlook, may prevent an automatic match.
  Matching text alone in another app never restores an Outlook conversation.
  The sidebar can display and copy an older draft, but only the active Composer conversation
  can refine, change its audience or replace the current target. Right-clicking a sidebar row,
  or pressing ⌘⌫ while the request field is not being edited, opens the shown conversation's
  Delete Conversation action, which VoiceOver also offers on each row. Deleting the active
  conversation also closes its panel, even when history could not be saved. Reopening a
  conversation that ran without Outlook context starts afresh once that context is enabled.
- **Composer's fixed rules stay outside its editable style.** Selected-text Composer prepends
  `boundary` and its meaning, register and approximate-length rewrite restrictions; caret-first
  composition and its refinements never add them. A selected-text refinement may change the length
  or add details the request states. Both modes append the body-only, natural-voice,
  no-em-dash and untrusted-email-context rules exactly once. When displaying or building a Composer
  override, a pure function removes exact copies of those fixed blocks, including the selected-text
  rewrite restrictions, and preserves the remaining style text. This also handles stored full
  prompts under the `rewrite` key without migrating settings or guessing at user-authored wording.
  Fix Grammar and Summarize overrides replace their entire prompt, including any source boundary.
  A custom action *is* the prompt, so `boundary` is prepended and no control removes it.
- **Each model action owns its instructions and its route.** The pencil on Fix Grammar, Composer and
  Summarize opens a sheet with the action's model and its override or default instructions. Composer
  edits only the writing style shared by selected-text rewriting and caret-first composition;
  Fix Grammar and Summarize edit the whole prompt. Saving compares against that editable default
  and changes only the action's instructions and model override; Use Default restores the editable
  instructions without changing the model. Blank instructions count as the default, so clearing
  the text never sends a model an empty prompt. Translate has no editor because no model handles
  translation. The same pencil on a custom action opens its editor, which owns the name and glyph
  too.
- **A custom action never travels in a backup.** Neither the record, its shortcut nor its route, for
  the reason `quickActionInstructions` already doesn't: an import must never change what a shortcut
  does to somebody's documents. Its JSON sits outside `UserDefaults`, so no settings key can sweep it
  up, and `quickActionModelOverrides` is excluded like `quickActionModel`.

## The actions

`QuickAction` is `.builtIn(BuiltInQuickAction)` or `.custom(CustomQuickAction)`. Coordinator, panel,
runner and prompt all take that one type, and neither half has a code path of its own.

A fifth *shipped* action is one `BuiltInQuickAction` case, its prompt in `QuickActionPrompt`, and one
`CommandID` case for its launcher row. `CommandID.init(_ action:)` is exhaustive, so it cannot compile
without one.

The custom case carries the record rather than an id, so a run uses the prompt as it was when it
started.

| Action | Engine | Default result | Diff |
| --- | --- | --- | --- |
| Fix Grammar | provider | replaces directly | yes |
| Composer | provider | panel | yes |
| Translate | Apple Translation | panel | no |
| Summarize | provider | panel, always | no |
| a custom action | provider | panel | no |

A custom action previews by default, switchable to Replace per row: Tinycast cannot know whether an
arbitrary prompt transforms the text or answers a question about it, and only the second destroys what
it replaces. No diff, for the same reason.

Custom instructions stay on this Mac and are excluded from settings backups, like chat's system
prompt, because importing them would change results without the reader seeing them first.

## Custom actions

`CustomQuickAction` is `id`, `name`, `iconSymbol`, `instructions`, `previewsResult`, `createdAt`.
`CustomQuickActionStore` keeps them as JSON in Application Support, ordered by `createdAt`, under an
injected directory so the harness gets a throwaway one. Name and instructions must be non-empty;
nothing else is rejected, including a name a shipped action already uses.

**Replace / Preview rides the record.** `QuickActionSettings` keys on `BuiltInQuickAction`, which
cannot hold a UUID, and a parallel dictionary would outlive what it described. On the record, a delete
takes the choice with it.

**`AppEntry.Kind.quickAction` is one section for both halves**, ungated in
`VisibilityStore.allowsHotKey` because `quickActionsEnabled` is the master switch. The four keep their
`CommandID`s, so no shortcut or preference key moved. A custom action binds
`HotKeyAction.quickAction(id:)` under `hotkey.quickAction.<uuid>`, indexed in `boundQuickActionIDs` so
`HotKeyManager.start` can prune a binding whose action was deleted while Tinycast was off.

**The pane draws its own `AliasField`.** The four are named in `SettingsTab.ownedCommands`, so
Settings → Commands no longer draws theirs. Without it, `deleteCustomQuickAction` would be clearing an
alias no surface could set.

**Nothing is saved until it is on disk.** `commit` persists before it moves `actions`, and a write
that cannot land throws `.storageUnavailable` where the reader sees it. An absent file is a fresh
install; one that exists but will not decode sets `isAvailable` false and makes every mutation refuse.
`QuicklinkStore`'s rule: authored data is reported on, never written over.

**Deleting unwinds only once the record is gone.** Confirm, remove, *then* drop the binding, the
route override, the favorite, the alias, the visibility key and the ranking. `WindowLayoutCoordinator`'s order: a failed
delete must never leave a kept record stripped of its shortcut.

Only Fix Grammar applies unseen: it changes what was wrong, where a rewrite changes the voice.
Summarize can never be told to replace text unseen — it answers a question *about* the text, so
replacing the text with the answer has to be a choice made in the panel. Every other default is a
**Replace / Preview** popup in the pane — a popup rather than a second checkbox, because the trailing
checkbox column means "show in the launcher" in every pane the app has. `QuickActionSettings` stores
only what the reader actually changed, so a new action arrives with its own default rather than
whatever a missing key would have meant.

## Translation

`TextTranslator` uses Apple's translator rather than the language model: it runs on device, costs
nothing on every route, and a 3B model is markedly worse at it. `NLLanguageRecognizer` supplies the
source language, because `TranslationSession(installedSource:target:)` needs a concrete one and
`LanguageAvailability` reports only a status.

`TranslationError` is annotated `macOS 26.4` while the deployment floor is `26.0`, so failures are
caught as plain `Error` and reported by what was asked rather than by matching its cases.

**The picker offers Apple's own list, never the reader's preferred languages.** `supportedLanguages`
is 47 entries on macOS 26 and is the framework's to change; building the menu from
`Locale.preferredLanguages` instead would put a language the translator cannot reach in front of
someone, where it could only fail at press time. Notably **Bengali is not among the 47**. The list
loads asynchronously, so the coordinator holds it as observed state rather than a computed property.
Names come from `minimalIdentifier` — the maximal form carries the script, and `es` would read
"Spanish (Latin, Spain)" in a menu that should say "Spanish".

A pair that is supported but not downloaded **opens the panel**, whatever the action's usual result,
so a shortcut never silently does nothing. **The download happens in System Settings.**
`prepareTranslation` never showed its sheet over this non-activating panel, so the prompt says where
to go — Language & Region → Translation Languages… — and its one button opens that pane and closes
the panel. System Settings has no anchor for the sheet itself, so the last click stays the reader's.

## The panel

`QuickActionPanel` is Tinycast's **fourth borderless surface**, beside the dialog, the notes panel
and the join preview. It takes the same recipe — `panelScrim`, then `GlassEffectView`, then the
clip — and sits at `.floating` like the join preview, so a failure report still lands on top of it.
Its footer speaks the same button language as a dialog's — `ModalActionButtonStyle`, with Replace
as the `.primary` role — so every borderless surface answers in one voice rather than dropping Aqua
controls onto vibrancy.

`ComposerToolbar` shows the captured-context status and the effective audience tone together in the
header. `ComposerModelControls` places model and reasoning controls in the footer, opposite the delivery buttons. The
context inspector displays the
actual recipient list, subject and bounded quoted text used by
the request. Missing fields produce a partial or unavailable status. Saved conversations do not
claim live context, because their quoted text is not retained. `OutlookComposeContextReader` aggregates
all addresses exposed by the To, Cc and Bcc fields, deduplicates them and removes presence labels.

The audience menu offers Automatic, Internal and External. Automatic shows the detected result;
Internal or External is saved with that conversation. Choosing the current option again saves
nothing, so it never extends retention. The menu is hidden while a saved conversation is on screen,
as the model and reasoning controls are. The model menu uses
`AIModelOption.availableGroups` and persists only Composer's route override. Until the signed-in
Claude CLI is ready, a Claude section there turns the provider on, copies its sign-in command or
opens its install page; the sign-in itself needs a terminal, so opening the menu re-probes.
Reasoning choices come
from the selected provider's catalog. Changes apply to the next request, including refinements,
without regenerating the draft or changing AI Chat's model. Footer controls are disabled during
generation. Escape closes an open inspector or menu, including a sidebar row's right-click menu,
before closing Composer; Return chooses a highlighted menu item without submitting the field or
replacing the Outlook draft. While an input method has marked text in the field, every key goes to
the input method first, so Escape cancels the composition rather than the panel.

It could not have been built on `HUDPresenter`: `HUDPanel` sets `ignoresMouseEvents` and returns
`false` from `canBecomeKey`, so it is click-through and hosts no buttons. Nor on `DialogAccessory`,
which is a closed two-case enum measured once at present time — a growing stream would clip.

Non-activating, so the target app keeps its selection or insertion point while the panel holds key.
Keys go through `sendEvent`: `⌘↵` delivers, as does `↵` outside a text field, `⌘C` copies the shown
result outside a text field, and `esc` dismisses. Composer labels delivery
**Replace** when the shortcut captured selected text and **Insert** when it captured only the caret. A
resumed Outlook conversation names its effective target instead, described under delivery below. In
caret-first Composer, `↵` submits the first writing request. When that first field is blank and the
captured context includes a quoted email message, `↵` visibly adds a context-only request and drafts
the reply without another instruction. A subject and recipient alone are not enough. After a draft
exists, `↵` submits another non-empty refinement. Ordinary editing shortcuts stay in the field.
Composer renders the first request, first
draft, every refinement request and every revised draft as one chat transcript. The provider receives
that same conversation with the bounded Outlook snapshot as its opening context, so a later request
can refer to an earlier version. A left sidebar lists the active Composer conversation and the last
seven days of saved transcripts. It starts collapsed and remembers the reader's last choice across
Composer sessions. The icon at the left of the Composer header opens it, and its own header hides
it again, returning to the active conversation. Older entries are view and copy only. Nothing
reaches the target app until Insert or
Replace. Generation errors appear in the transcript, and the failed request returns to
the input field. Retrying excludes failed turns from the model conversation. Stop keeps the last
completed draft available for Copy, Insert or Replace, except when a different Outlook selection is
awaiting its first successful rewrite. That selection remains source text and cannot be delivered.
Reopening an interrupted session marks unfinished responses as failed. A selected-text conversation
reopened without a draft offers Retry, because the selection is already its request.

A dismissed Composer conversation stays reachable, whether its draft arrived behind the closed
panel or before it closed. Pressing the shortcut again in the same text field with the same
selected text in the same range, or the same caret in a field whose length has not changed, or on
the same passage of an unchanged note, reopens it as often as needed. A different field, selection,
caret, field length or note starts a new conversation, which replaces it, and so does a field that
reports no selection range. Insert or Replace ends it. A conversation whose panel asks to reopen
Composer captures afresh instead. This applies only outside an Outlook-context draft. That draft is
restored from history instead, so its captured body is never stale.

Composer opens centered over the visible source editor, using bounds captured before its panel opens.
`ComposerPlacementReader` falls back to the source window when the editor has no usable bounds.
This geometry-only read also works with Outlook context disabled. A note centers it over the note
window and never reads Outlook context or history, even with Outlook frontmost.
`ComposerPanelPlacement` chooses the source display and keeps the panel clear of its edges. Other Quick Actions open near the pointer.
Resizing uses the panel's current display, so moving the pointer cannot move Composer to another screen.

Click-away dismisses like every other borderless surface. The panel is anchored by its **top-left**
and re-measured as the reply arrives. A Composer panel may grow while it is open, but it keeps the
largest height it has reached when the reader switches between saved conversations. Its larger
minimum body leaves room for the first writing request before a transcript exists. Centring on every
measure would walk it up the screen. `MarkdownView` and `MarkdownBlock.parse` are reused from chat;
neither takes palette state.

The body is a `ScrollView` with its height **set** rather than capped: a scroll view has no ideal
height, so `NSHostingView.fittingSize` measures it as nothing and the body collapses to a slot. The
content's ideal height is measured with `fixedSize` + `onGeometryChange`, the way the Support and
Updates windows size themselves.

The scroll view owns the **whole** panel and the bars are overlays on top, so a result dissolves
beneath them rather than stopping at a line. The mask is clear for each bar's height, ramps over
`quickActionScrollFade`, and the content is inset by bar + ramp — so the first line starts fully
opaque and only dissolves once it has scrolled up into the gradient. It is skipped entirely when the
result already fits, since dimming text that needs no scrolling reads as a defect.

Three things here were settled by rendering them, not by reasoning:
`scrollEdgeEffectStyle` draws nothing in this panel — it renders a material where a scroll view meets
a safe area, and over `panelScrim` + `GlassEffectView` that composites to nothing. `safeAreaBar`
makes it visible but lays its bars *over* the content instead of insetting it, so text runs through
the buttons and escapes the corner clip. And a ramp starting at the panel edge rather than below the
bar leaves text about 60% visible behind the title.

`TextDiffEngine` shows what changed when the output is the input, edited. Its traceback is
quadratic, so past `maxTokens` a side it degrades to whole-text rather than asking for gigabytes.
It keeps one rolling `UInt16` score row and one insert-or-delete bit per token pair — equality is
re-checked during traceback — so the cap costs about 2 MB where a full score matrix cost 32 MB.

## Reading the input

For selected text, two tiers run in order. `AccessibilityText.read` asks for
`kAXSelectedTextAttribute`, then the
text-marker range browsers use instead. `AXManualAccessibility` is set on the application element
first, because Chromium builds its accessibility tree only once something asks and Chrome, Electron
apps and VS Code otherwise answer every attribute with nothing.

When Accessibility yields nothing, `TextInjector.copySelection` borrows a ⌘C: snapshot the
pasteboard, synthesise the chord, wait for `changeCount` to **move**, read, restore. It lives on
`TextInjector` because the pasteboard has one owner — the same lease, queue and `ClipboardManager`
coordination a paste needs, and a second owner would race it.

**The `changeCount` guard is load-bearing.** With nothing selected, ⌘C is a no-op; returning the
pasteboard's existing contents there would transform whatever the reader last copied and paste it
over their selection. Movement is the only proof a copy happened — never comparing content, which
false-positives when the same text was already on the clipboard.

For Composer, an empty selection with a zero-length `kAXSelectedTextRangeAttribute` is a valid
insertion point. The coordinator opens the panel without calling the provider. It captures Outlook
context at that moment, and the first Send starts generation. Other actions still require selected
text.

Copying is the selected-text fallback and never the first try: it synthesises a keystroke into
somebody else's app. When the selection tiers come back empty, only an Accessibility result of
`.empty` justifies "nothing is selected"; otherwise the app told us nothing either way and says so.

## Delivery

Notes replaces the captured range through its own TextKit edit path, with undo and autosave. If the
note, source or selection changed while the result was generated, delivery declines and copies the
result instead of replacing another passage.

For external apps, `TextInjector` — shared with Snippets and Quicklinks, and owned by `AppCore` — does
the replacement.
`replaceSelection(with:in:)` takes the interactive path: no keyword to match, no generation to
cancel, because a shortcut is an explicit gesture rather than an expansion the app decided to
attempt. Its serial delivery queue is what stops two features fighting over the pasteboard lease.

The Accessibility tier replaces the live selection atomically, under the five-rule delivery contract
in [snippets.md](snippets.md#text-delivery-and-pasteboard-safety) — Quick Actions simply enter it with
no keyword, so rule 2 never applies. The event tiers behind it type or paste over the selection, which
every app treats as replacing it — but that is the target app's behaviour rather than something
Tinycast asserts, so it is the part worth checking by hand.

**A replacement that never lands says so, and keeps the reply.** Every tier can decline, and a shortcut
that quietly did nothing is indistinguishable from a shortcut that is not bound. `DeliveryCompletion`
now settles either way, so a delivery that returned early reports failure exactly once; Quick Actions
put the generated text on the clipboard and raise a HUD rather than dropping it. Snippets pass no
failure handler, so automatic expansion stays silent as before.

Outlook Composer formats only a target that starts at a line start and ends at a line end, or a
caret on an empty line. **Insert** preserves following line breaks and adds one only when none exists.
A selected-text Replace ending with `Best,` adds only the line breaks needed to reach two before the
existing signature; reopening and replacing the same draft never adds another blank paragraph.
A selection's own leading and trailing whitespace is left in Outlook rather than replaced, since
Outlook drops a pasted trailing line break and a triple-clicked paragraph would lose its blank line.
Composer's Outlook capture already leaves it out of the replaced range; every other Outlook delivery
(Fix Grammar, Translate, custom actions, Composer without Outlook context) narrows the live
selection to exclude it just before pasting, and keeps the full selection if Outlook refuses.
A result that already carries those edges, such as text Translate leaves unchanged, replaces the
whole selection instead.
Later checks in the same delivery expect the narrowed selection, and a delivery that fails before
anything lands selects the original range again.
Other apps replace the selection itself, so every Quick Action hands its leading and trailing
whitespace (line breaks, and the space a double-clicked word carries) back around the result; a
selection without any gets the result as the provider wrote it. The selection's indentation goes
back only on a one-line result; a multi-line result keeps its own, so its lines stay aligned. A note decides this by the note,
not by the app behind it.
A one-line, multi-sentence draft becomes short paragraphs only within those whole-line boundaries.
Mid-line targets, existing line breaks and lists keep their paragraph structure. Other sign-offs,
apps and Quick Actions keep the provider's output unchanged apart from that edge whitespace. Completion strips a leading
model-generated subject only when the source did not already begin with a subject line.

With Outlook context enabled, `ComposerTextTarget` verifies the captured editor and body inside the
delivery queue, after activation. It selects the captured draft range and verifies that Outlook
accepted the selection before replacement. A mismatch leaves the source untouched and copies the
result instead. The event fallback checks the target again immediately before insertion.

Every other external target gets the same check in a narrower form. When the shortcut is pressed,
the coordinator captures the focused Accessibility element and its selected range, or the caret,
for every Quick Action, before reading the selection. Focus that moves during the ⌘C fallback
cannot redirect delivery, and an Outlook capture read after it counts only for that same editor and
range. After activation, delivery checks the original element's range when reported and compares
captured selected text when available. A different focused element is accepted only in the same
process with identical non-empty selected text. Caret insertion requires the original element and
range; a field that reports neither is held to focus alone. An app that exposes no focused element
cannot be checked, so activation is its only guard.

When Composer resumes a saved email, the boundary fingerprints locate its current draft, and the
press decides the target. Selecting that draft, or placing the caret inside it or at its edges,
targets the whole draft. Manual Outlook edits become a new draft in the conversation and supply the
starting text for further changes. A different selection targets that text instead, adds it as
user-supplied source text and automatically requests a rewrite in the same conversation. Delivery
stays disabled until that model turn succeeds; failure or Stop retains the selected source and request
for retry, including after reopening. When the saved boundary no longer resolves, or none was saved,
an explicit selection instead re-anchors the conversation and is recorded as a manual Outlook edit,
without a model request. A caret anywhere else inserts there, including when the saved boundary has
gone stale. The button says **Replace** or **Insert** by that effective target. A different selection
or outside caret moves a valid saved boundary only once a draft lands there. A selected-text press
without a usable range disables Replace with a request to select the draft and reopen Composer.

### Manual sweep

- Open Composer in an Outlook reply with several To recipients. Inspect Email context captured and
  confirm every address appears once, with the subject and bounded quoted text. Check partial context
  in a new email, unavailable context outside Outlook, and the saved-conversation notice in history.
- Configure an internal domain, then open an internal email, an external email and a mixed-recipient
  email. Confirm the footer reports Internal only when every captured recipient matches. Override an
  internal conversation to External, leave it, reopen the same email, and confirm the override stays.
- Change Composer's model and reasoning from its footer. Confirm the next refinement uses that route,
  the choice survives reopening, and AI Chat's route remains unchanged. Composer offers whatever the
  connected Codex catalog reports and AI Settings shows; a saved model the catalog has dropped moves
  to its default. With Claude off, signed out or not installed, confirm the menu's Claude section
  offers to turn it on, copies `claude auth login` or opens the install page, and lists Claude's
  models the next time it opens after sign-in.
  During generation, confirm both controls are disabled. Open a menu, use arrows and Return, and
  confirm Outlook stays untouched.
- Right-click a sidebar row with text in the request field. Confirm Escape closes only the menu,
  arrows stay in the menu, and Return deletes the conversation without sending the request or
  replacing anything in Outlook.
- Compose Japanese or Chinese text in Composer's field with an input method. Confirm Escape cancels
  the composition and Return commits it, while the panel stays open.
- In TextEdit, run Fix Grammar in Replace mode and click elsewhere in the document before it
  finishes. Confirm the text is untouched and the result is copied. Repeat after moving focus into
  its Find bar, and confirm the Find field receives nothing.
- In TextEdit, start Composer generation, dismiss the panel and wait for it to finish. Press the
  shortcut in the same field and confirm the finished draft reopens, ready for refinement or Insert.
  Dismiss and press again to confirm it reopens every time, then select other text and confirm the
  shortcut starts a new conversation. Repeat with selected text, then retype that range with
  different words of the same length and confirm a new conversation starts. In a caret-first
  conversation, type in the field before pressing again and confirm a new conversation starts.
- In a Tinycast note, select a passage, run Composer, dismiss the panel and wait for it to finish.
  Press the shortcut on the same selection and confirm the draft reopens and Replace lands in the
  note. Change the selection and confirm a new conversation starts.

- Select text in Safari, Chrome, Brave, Slack, Mail, Notes, VS Code and Terminal, press Fix Grammar,
  and confirm the selection is **replaced** rather than appended to.
- Select text in a Tinycast floating note and run Fix Grammar by shortcut and launcher row. Confirm
  replacement, Undo, and that changing the note before pressing Replace copies instead.
- In a Chromium target, run one on a **short** selection whose result stays under 100 characters on
  one line: the whole result lands, not its first four characters.
- Replace mode, with a slow route selected: the message pill says `Fixing Grammar…` with a blue
  spinner while the model works, and the result message takes its place.
- Dismiss a finished Composer conversation in TextEdit, run Fix Grammar in Replace mode in another
  document and cancel it from the pill. Confirm the Composer conversation still reopens from its field.
- Run one from the launcher (⌘Space → "Fix Grammar") with text selected behind it: the palette
  closes and the selection in the displaced app is what gets acted on, not Tinycast's own field.
- Uncheck an action's launcher checkbox: the row leaves ⌘Space, and its shortcut still works.
- Add a custom action, bind a shortcut, run it from the shortcut and from ⌘Space, then rename it and
  confirm the shortcut, the Replace choice and the checkbox all survived.
- Delete a custom action with a shortcut bound: the dialog asks first, the row leaves both Settings
  and ⌘Space, and the chord is free for something else to take.
- Type "quick actions" in ⌘Space: the section lists the shipped four beside the custom ones.
- Give Fix Grammar and a custom action an alias in the pane, then type each alias in ⌘Space.
- Press a shortcut with Tinycast's own Settings window frontmost: refused, with a HUD.
- Press one in a password field: refused.
- Summarize a long selection: the panel streams, grows without the title drifting, and scrolls past
  `quickActionPanelBody`.
- Replace Composer's instructions, confirm only Composer follows them after relaunch, then use the
  modal's default and confirm the shipped behaviour returns.
- Enable Outlook context, select a rough draft at the top of an Outlook reply, and run Composer.
  Confirm the result reflects the recipient, subject and newest exchange, while the signature and
  older quoted history are absent from the request and only the selected draft is replaced.
- Place the caret in an empty Outlook reply and run Composer without selecting text. Confirm the panel
  opens before any model request, the first field is focused, and the email context reflects the
  moment the shortcut was pressed. Enter a writing request, press Return, refine the result, then use
  Insert. Confirm the finished draft is inserted at the original caret.
- Type part of a caret-first writing request, dismiss the panel, navigate away, then return to the
  same Outlook email and run Composer. Confirm the unsent request reappears and a different thread with
  the same recipient does not inherit it.
- In Composer's panel, ask for a warmer version, then a shorter one. Confirm both requests and all three
  drafts remain in the transcript, a reference to an earlier version works, and Outlook remains
  untouched until Insert or Replace is clicked.
- Replace an Outlook Composer draft that ends with `Best,`. Confirm one blank line remains between the
  sign-off and the existing Outlook signature.
- Replace a one-line Outlook Composer draft with three sentences. Confirm each sentence lands as a
  separate paragraph, then replace a draft with existing line breaks and confirm they remain
  unchanged.
- Dismiss the panel, run Composer on another email, and select the first email in Recent drafts.
  Confirm its full transcript remains available to copy, delivery is unavailable, and the active tab
  restores the current draft. Switch between short and long conversations and confirm the panel does
  not shrink. Move the stored clock past seven days and confirm the old tab is gone.
- Dismiss Composer, navigate to another message, then return to the same Outlook email and run Composer
  again with the caret inside its saved draft. Confirm the transcript and latest draft reopen without
  generating a new first draft.
  If the sidebar contained duplicate rows for that email, confirm they collapse into one conversation.
- In an Outlook reply, select a paragraph, run Composer and Replace. Select a different paragraph and
  run Composer again: confirm the same conversation opens with that paragraph as user-supplied source
  text, shows a rewrite request and starts generation automatically. Confirm Replace and ⌘↵ remain
  unavailable until the model finishes, then only that paragraph changes. Repeat with a slow or
  failing model, Stop, dismiss and reopen: the selected source and request must remain retryable and
  unavailable for delivery until a rewrite succeeds. Place the caret outside both and confirm
  the button says Insert and the draft lands at the caret; place it inside the first draft and
  confirm the button says Replace and that draft is replaced.
- Change text outside a saved Outlook draft so its boundary no longer resolves, explicitly select
  the edited draft and reopen Composer. Confirm the transcript says it was edited in Outlook, no
  generation starts, and further changes replace that selection. Reopen again and confirm the new
  boundary resolves. Repeat with a conversation that has no saved boundary.
- Run Composer in a private reply to one person, then open Reply All to the same message and run
  Composer. Confirm a new conversation starts, both stay in the sidebar, and each editor reopens its
  own.
- Type an unfinished refinement, dismiss Composer, then return to the same email. Confirm the input
  reappears, submit it, dismiss again, and confirm the field reopens empty.
- Right-click a saved Composer conversation and choose Delete Conversation. Confirm it disappears
  and stays absent after relaunch. Delete the active conversation and confirm its panel closes.
  Select a saved conversation, press ⌘⌫ and Return, and confirm it is deleted; with VoiceOver,
  confirm each row offers Delete Conversation in its actions.
- With a saved conversation selected in the sidebar, confirm the audience menu is hidden and the
  active conversation's audience is unchanged when you return to it.
- Give Summarize its own model and effort: the row names them, only Summarize uses them, and they
  survive a relaunch. Turn that provider off in AI Settings and Summarize follows the shared model.
- Save a custom action with its own model, delete it, and confirm no route is left in
  `quickActionModelOverrides`.
- Translate into a language that has not been downloaded: the panel names the language, and its
  button closes the panel and opens Language & Region.
- Revoke Accessibility while enabled: a HUD explains instead of failing silently.
- Harnesses: `quick-action-test` (action metadata, prompt boundaries, Outlook context trimming,
  seven-day Composer history, preview choices, routes and their repair),
  `composer-test` (replacement boundaries, manual edits, failures, interrupted requests, which
  conversations reopen, resumed delivery targets, scoped history matching, separate replies to one
  message and newest quoted messages), and
  `text-diff-test` (exact chunks, coalescing, Unicode, ties, token boundaries and fast paths).
