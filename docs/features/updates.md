# Updates

By default, Tinycast checks GitHub Releases once a day and offers the newest release for its own
channel in a native window with its release notes, installs it and relaunches. There is no Sparkle and
no appcast: the release feed the website already reads is the feed the app reads.

## Invariants

- **Tinycast installs its own updates, and Homebrew stays out of the way.** Both casks declare
  `auto_updates true`, which is Homebrew's own flag for an app that manages its own version. `brew
  update && brew upgrade` therefore skips Tinycast entirely — it is never reported outdated, never
  re-downloaded, and a self-updated copy is never trashed or rolled back. `brew install`, `brew
  uninstall` and `brew list` keep working unchanged.
- **The archive is a zip, never the DMG.** A zip expands with `ditto`; a DMG would have to be mounted,
  which means a volume, a Spotlight handle and a detach that can fail. A release published without a
  zip is not installable and is not offered.
- **The zip is chosen by architecture.** A stable release carries a thin arm64 zip and a
  `-Universal-` one. Intel takes the universal zip and is offered *nothing* if it is missing, since a
  thin build would install and then refuse to launch; Apple silicon prefers the thin zip and falls
  back to universal.
- **Nobody ever runs `xattr`.** An archive Tinycast fetched itself is not quarantined — macOS sets
  that flag for sandboxed downloaders and for apps that opt in with `LSFileQuarantineEnabled`, and
  Tinycast is neither. `Quarantine` checks anyway through `getxattr`/`removexattr` rather than the
  `xattr` tool, and an app that still carries the flag is refused rather than installed.
- **The signature is the only integrity guarantee.** A downloaded bundle is trusted when its seal
  validates, nested helper included, *and* it either satisfies the Developer ID requirement pinned in
  `BundleSignature` or carries the byte-identical leaf certificate the running app does. The
  requirement names the team, so a certificate renewal strands nobody; the leaf match is the path a
  copy installed before the Developer ID switch has, and it goes away once none is left. A fork accepts only its running leaf certificate; it does not trust upstream
  Developer ID signatures. `notarized`
  is deliberately not in the requirement — it resolves the ticket through `syspolicyd` or the
  network, so an offline Mac would refuse a bundle the chain already proves is ours.
- **A build only ever updates within its own channel.** The channels are separate bundle ids installed
  side by side; crossing would mean installing a different app. `com.tinycast.app.dev` never updates
  at all, and does not advertise the command.
- **Nothing is installed unless every check passes.** Bundle id, version, update repository and signature are all checked
  on the expanded copy before `replaceItemAt` runs, and the running app survives any failure untouched.
- **Relaunching goes through `NSApp.terminate`, never `exit`.** That is what flushes a pending note
  draft and hands back the Hyper Key's HID-level caps remap, which outlives the process.
  Relaunch schedules termination through the main run loop, outside any Swift task or dispatch
  callback, so AppKit's nested termination loop can run the main-actor cleanup. The delegate returns
  `terminateLater` and replies when cleanup finishes, preserving system logout and shutdown requests.
  A reopen is scheduled once, only when termination is committed, and waits for the old process to exit.
- **An automatic prompt defers to whatever the user is doing, and is never spent unshown.**
  `UpdateReadiness` withholds it while a snippet is expanding, an extension command is running, an
  uninstall is trashing, a shortcut is being recorded, a prompt or dialog is up, or the palette is
  open. A withheld prompt is still owed: `presentIfAvailable` answers `false`, the version is left
  unannounced, and the pump re-offers it every two minutes for half an hour before falling back to
  the daily rhythm. That is what a hand-launched copy depends on — its one announcement falls 30 s
  in, straight into the palette the user opened the app to use, where a launch-at-login copy would
  have found the desktop idle. The window itself still appears at most once per version per launch:
  `announcedVersion` is set the moment an offer lands, so re-offering can never turn into nagging.
  Readiness is asked again at the click.
- **Automatic checking is optional; manual checking stays available.** Settings → General →
  Automatically check for updates defaults on. Turning it off stops the background task and any
  in-flight automatic request, so neither a response nor a cached release can raise a new prompt.
  The preference travels through settings backups and `general.automaticallyCheckForUpdates` in
  settings.json; release metadata and skipped versions stay in the feature's own cache file.
- **The window shows the changelog and nothing else.** CI writes install instructions below
  `<!-- tinycast:install -->`, and `ReleaseNotes.summary` — the single reader of that marker, called
  where the feed is parsed so the cache holds the cut text too — drops them. An app that installs its
  own updates has no use for a Homebrew command, and a body published before the marker existed has
  none, so it comes back whole.
- **The notes are laid out by `ReleaseNotesView`, which is this feature's own.** `AttributedString`
  parses inline styling only; headings and bullets are placed by hand or they arrive as literal `##`
  and `*`. `ExtensionMarkdownView` does the same job and is deliberately not reused — an extension's
  views never leave `Features/Extensions/`.
- **`@handle` and `#304` are linked by the app, never by the release body.** GitHub autolinks both on
  the web, and a bare mention is what notifies the contributor, so the published body keeps them
  plain and `ReleaseNotes` spells them as Markdown links on the way to the window. Both point at
  `ReleaseFeed.repository`. Official builds read `abue-ammar/tinycast`; this fork defaults to
  `tehss1/tinycast` for local
  builds and falls back to that fork if its stamp is absent or invalid; fork workflows stamp their
  own repository into `TinycastUpdateRepository` at build time.
- **A private fork's token lives in Keychain and nowhere else.** Settings → General → Update token
  appears only in a build stamped with its own repository, and stores a read-only GitHub token under
  the `update-token` Keychain scope. It is never written to preferences, `settings.json`, a backup or
  the update cache. It is sent to `api.github.com` alone: the asset download redirects to signed
  storage on another host. Both the feed check and downloader strip `Authorization` before following
  a redirect to another host or to non-HTTPS storage, using the same redirect policy.

## Channel and version

`ReleaseChannel` is derived from the bundle id, and nothing else:

| Bundle id | Channel | Takes |
| --- | --- | --- |
| `com.tinycast.app` | `.stable` | releases |
| `com.tinycast.app.beta` | `.beta` | prereleases |
| anything else | `.development` | nothing |

`AppVersion` parses `MAJOR.MINOR.PATCH`, `MAJOR.MINOR.PATCH-beta.N`, and customized stable
`MAJOR.MINOR.PATCH-composer.N` versions. Ordering is beta, official stable, then Composer for one
matching base version; counters compare numerically. Everything else parses to nil, so an off-shape
tag can never be offered as an update. A release whose tag disagrees with its `prerelease` flag is
treated as mis-published and skipped.

The Intel build is *not* a channel. It shares the stable tag, version, bundle id and signature, so it
resolves to `.stable` like any other; `ReleaseArchitecture` picks its asset, and nothing about
identity changes.

## Checking

`UpdateCheckStore` copies `CurrencyRateStore`: a private `.ephemeral`, `urlCache = nil` session, a
self-rescheduling pump, and one atomic JSON file.

```text
~/Library/Caches/<bundle-id>/update-check.json
```

It holds `lastCheckedAt`, the newest release seen, and the version the user dismissed. A cached
release is decoded only when its tag parses to the same version; the archive filename comes from
the validated version, so a tampered tag cannot write outside the staging directory. Freshness is
measured from `lastCheckedAt`, so relaunching never re-asks GitHub; the interval is 24 h, dropping to
2 h after a failed attempt, and the first check waits 30 s so it never lands in the login rush. The
request carries a `User-Agent`, which the GitHub API rejects requests without, and the update token
as a bearer credential when one is stored. The download sends the token only when the asset address
is `https` on `api.github.com`, since that address is read back from this file, and drops it on the
redirect to signed storage.

GitHub answers 401 for a bad token and 404 for a private repository the request may not read. Both
are a refusal rather than an outage: Check for Updates reports that access was refused and points at
the token. A 404 without a stored token means the repository publishes no releases, and says so
instead of blaming a token the build never had. A 403 is a rate limit only when
`X-RateLimit-Remaining` is zero or `Retry-After` is present; otherwise it reports access refused.
A 429 always reports a rate limit and asks the reader to try again later.
A manual check made while another is still in flight reports that a
check is already running. Any other failure says GitHub could not be reached.

Disabling automatic checks takes effect immediately and survives relaunch. Turning them back on
resumes the same schedule, with the startup delay and cached check time respected. Check for Updates
always works independently of this preference, including while automatic checking is disabled.

**Later means skip.** It records the version, so that release stops asking; a newer one still asks.
Check for Updates ignores the record and always offers whatever is newer than what is running.

## Local release notification

After publication, `Scripts/release-local.sh` checks `pgrep -x Tinycast` and posts the payload-free
`com.tinycast.app.release-published` distributed notification. It never opens or installs an app.
A missing process is logged; notification failure warns without failing publication. Dry runs and
nothing-to-do exits precede this block. Delivery has no acknowledgement, so this log cannot prove
that an older installed build received or acted on the notification.

`ReleaseUpdatePolicy` accepts the signal only for stable `tehss1/tinycast` builds running at
`/Applications/Tinycast.app`, with Automatically check for updates enabled (the existing default).
That setting also owns this fork's unattended local-release installation; its caption explains it.
There is no separate automatic-install preference. Other repositories, channels and app paths ignore
the signal. Requests are coalesced while work is in flight and throttled to once per minute.
The notification supplies no URL, version, path or verification override. Another app can request
only the same feed check and normal verified update; it cannot select arbitrary software.

The coordinator requires a successful fresh feed response and a strictly newer parsed version.
It waits while any `UpdateReadiness` blocker is present, Quick Actions has running work, generation,
screenshot attachment or a pending history save, dictation is active, or any work window is
visible or minimized. Explicit work-window markers include Composer and Quick Action panels; status-item hosts
and passive HUDs do not block. Retained Composer sessions also block until the draft is finished
or discarded, because history cannot restore image bytes, live source targets or full captured
context. Idle state is checked every two seconds,
again on the main actor immediately before replacement, and again before requesting relaunch.
Download, extraction, quarantine, bundle, version, repository and signature verification all use
`UpdateInstaller`; no checks are bypassed. Failures are logged and leave the published release intact.
Disabling automatic checks cancels pending unattended work. After replacement, relaunch waits for
idle state and uses the usual termination cleanup, then `open -g` to return in the background.

The installed `v0.12.1-composer.23` has no notification receiver. One manual update to a build
containing this receiver is required before subsequent local releases can update it unattended.
The expected Keychain history-access prompt after self-signed updates is unchanged.

## Installing

One route, whatever the install came from:

1. Stream the zip into `~/Library/Caches/<bundle-id>/Updates/`, with real byte progress and a Cancel
   that actually aborts the transfer. The address is the asset's API `url`, asked for as
   `application/octet-stream`, because the browser download address cannot serve a private asset.
2. `ditto -x -k` it into a staging folder, and take whatever `.app` lands there — the bundle is named
   for its channel, so it is `Tinycast Beta.app` on beta.
3. Check quarantine natively; clear it if somehow present, and refuse the update if it survives.
4. Verify the bundle id, the version, the update repository, and that the code signature is valid and proves the bundle is
   ours — by the running app's own leaf certificate, or, for an official build only, by the pinned
   Developer ID requirement.
5. Check cancellation after downloading and expanding, and again before replacing.
   `FileManager.replaceItemAt`. The staging folder is on the same volume as `/Applications`, which is
   what lets this be atomic. A non-writable `/Applications` is reported, not worked around; there is
   no privileged helper.
6. Offer Relaunch, which spawns a detached waiter that reopens the app once this process exits —
   `open` on a bundle id that is still running would only re-activate the instance on its way out.

Nothing here touches `~/Library/Preferences`, `~/Library/Caches` or `Application Support`, so no
setting, clipboard entry, note or snippet is affected by an update, by `brew upgrade`, or by both.

## Releasing into it

`.github/workflows/release.yml` publishes two assets from one build: the DMG people download by hand
and the cask installs, and `Tinycast-<version>.zip` for the updater. A stable run adds a
`Tinycast-Universal-<version>` pair from its `universal` job, uploaded second so the thin zip stays
first in the asset list — builds predating architecture-aware selection take whichever comes first.
The zip is made with

```sh
ditto -c -k --keepParent --sequesterRsrc "$APP" "dist/$ZIP_FILE"
```

which is the only zip that leaves the code signature verifiable — plain `zip` drops symlinks and
breaks the seal, and the signature check above would then reject every update.

The body it publishes is composed by `Scripts/release-notes.sh`: GitHub's generated changelog first,
then `<!-- tinycast:install -->`, then the install text. Anything a release wants the update window to
show has to go above that marker — see [release.md](../release.md#release-notes).

**The casks must declare `auto_updates true`** in `abue-ammar/homebrew-tinycast`. Without it Homebrew
compares its Caskroom receipt against the cask version, sees a self-updated app as outdated forever,
and re-installs over it on the next `brew upgrade`.
