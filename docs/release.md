# Release

How a build reaches a user. The local development loop is in [development.md](development.md);
the signing identity itself is in [signing.md](signing.md).

## Packaging a DMG locally

```sh
./Scripts/build-dmg.sh            # -> build/Tinycast-<version>.dmg (version from project.yml)
./Scripts/build-dmg.sh 0.5.7      # -> build/Tinycast-0.5.7.dmg
```

It builds a Release `Tinycast.app` signed with `Tinycast Self-Signed` and packs it with an
`/Applications` symlink. Official per-channel releases are built by CI, below.

## Signing & Gatekeeper

Both local builds and CI releases sign with the same stable `Tinycast Self-Signed` identity, not an
Apple Developer ID — so macOS quarantines a directly-downloaded DMG. The Homebrew cask strips that
automatically; direct downloaders run `xattr -dr com.apple.quarantine "…/Tinycast.app"` once. Full
details in [signing.md](signing.md).

## How the in-app updater consumes a release

Every release publishes two assets from one build: `Tinycast-<version>.dmg`, which people download by
hand and which the cask installs, and `Tinycast-<version>.zip`, which the in-app updater installs. The
zip is produced with `ditto -c -k --keepParent --sequesterRsrc` — the only zip that leaves the code
signature verifiable, which matters because the updater refuses any bundle whose signature does not
prove it is ours.

A stable release publishes two more from the `universal` job, `Tinycast-Universal-<version>.dmg` and
`.zip`, built from the same commit at the same version and bundle id but with both slices. They are
uploaded *after* the thin pair, which keeps the thin zip first in the asset list so builds predating
architecture-aware selection keep choosing it.

Three things a release must keep true, or the updater skips it:

- **It carries a `.zip` asset this Mac can run.** A DMG-only release is not installable and is not
  offered, and an Intel build is offered nothing rather than a thin arm64 zip.
- **The tag parses as `vMAJOR.MINOR.PATCH`, `vMAJOR.MINOR.PATCH-beta.N`, or
  `vMAJOR.MINOR.PATCH-composer.N`,** and agrees with the `prerelease` flag. Composer versions are
  stable customized releases. A tag of any other shape is treated as mis-published and skipped.
- **It is not a draft.**

**Both casks declare `auto_updates true`.** That is Homebrew's flag for an app that manages its own
version, and it is what keeps `brew update && brew upgrade` from fighting an app that updated itself:
brew never reports Tinycast outdated, never re-downloads it, and never rolls a self-updated copy back.
Removing that line would reintroduce exactly those three problems. See
[features/updates.md](features/updates.md).

## Pull request review

`.github/workflows/verify.yml` runs the complete harness suite on pull requests and pushes to `main`.
It also regenerates the Xcode project, checks Composer retention, builds Debug without signing,
runs lint and checks model imports. Release runs must pass the same verification before accessing
signing secrets. CodeRabbit also reviews every PR against `.coderabbit.yaml`: it runs SwiftLint with
`.swiftlint.yml`, annotates the diff, and applies the pre-merge checks. CI is a backstop, so run the
whole bar in [testing.md](testing.md#definition-of-done) locally before opening a PR.

## Releasing

`.github/workflows/release.yml` builds and publishes a DMG from GitHub Actions, no local machine
needed. Run it from the **Actions** tab (`Release` → **Run workflow**) and pick:

- **channel** — `beta` or `stable`. Each builds a distinct app (`Tinycast Beta.app` / `Tinycast.app`)
  with its own bundle id, alongside the local `Tinycast Dev.app`. Beta gets an auto-incrementing
  `-beta.N` suffix (`N` = the Actions run number) so re-running never collides. Official stable
  releases ship the version as-is; fork stable releases add the Composer suffix described below.
- **version** — base semver, e.g. `0.2.0`.

It builds on a `macos-26` runner with Xcode 26 and publishes a GitHub Release tagged
`v<full-version>` with a versioned DMG and zip asset, marked prerelease for beta. On success it also
bumps the matching cask in the tap and announces the release on Discord. A stable run also
dispatches the Website workflow, because the site reads the latest version and the
[changelog](https://tinycast.dev/changelog/) from GitHub at build time.

### Customized release feed

A customized build keeps its changes while receiving official Tinycast improvements through a fork.
The fork's `main` branch owns the custom code. `.github/workflows/sync-upstream.yml` checks the
official repository every day and follows its latest stable release tag rather than `upstream/main`,
so the fork only ever ships code the official project has published. A new release is merged onto
`automation/upstream-sync`, tested with `.github/workflows/verify.yml`, fast-forwarded into `main`,
and published by dispatching the Release workflow with the official base version. A `main` that
already contains the release but has no matching `-composer` release is published the same way.

A merge conflict, a Composer file deletion or missing ownership/encryption/feed wiring, a failing
test or a `main` that moved stops the run before anything reaches
`main`, and opens one issue per official release, labelled `upstream-sync` and assigned to the
fork's owner. A cancelled run reports the same way. Merge that release into `main` locally and push;
the next run publishes it and closes the issue. The sync branch is deleted only after the Release
workflow is dispatched. A Release run that then fails or is cancelled opens its own issue, labelled
`release-failure`, since nobody is watching a build the sync started. The default Actions
token may not push a change under `.github/workflows/`, so a release that carries one stops the same
way unless the fork has a `SYNC_TOKEN` secret: a token with contents and workflows write access.

A fork that cannot run Actions does the same from a Mac with `./Scripts/release-local.sh`: the
merge, the Composer retention check, then `verify.yml`'s checks with a Debug build that adds no new
warnings, a plain push to `main`, then the Release workflow's `build` job signed with
`Tinycast Self-Signed` from the login keychain. It numbers the build one past the highest
`-composer.N` release rather than an Actions run, and checks that the leaf certificate matches
`/Applications/Tinycast.app`. It exits 2 on a conflict, leaving the merge on
`automation/upstream-sync`; commit the resolution and rerun it from that branch. `--dry-run` builds,
signs and packages without pushing or publishing, rebuilding `main` when there is nothing new.
`--release-main` publishes `main`'s own changes when upstream has nothing new.
The local script retries its `git fetch`, `git ls-remote`, latest-release API and `gh release list/view`
reads up to three times, capped at 120 seconds each with waits of 15 then 45 seconds
(`TINYCAST_NETWORK_TIMEOUT` and `TINYCAST_NETWORK_RETRY_DELAYS="15 45"` override these for fixtures).
Pushes and release creation run once, and a missing remote ref is never retried.

This fork defaults local builds to `tehss1/tinycast`. The release workflow stamps `github.repository` into `TinycastUpdateRepository` in the built app.
The in-app updater then reads releases from the repository that built the app. The official workflow
still stamps `abue-ammar/tinycast`, while a fork stamps its own `owner/repository` value. Both paths
retain bundle, version, architecture, signature and downloaded-repository checks.

Publish a stable fork release using the base version of the official release it includes. The fork
adds `-composer.<Actions run number>` automatically, so its tag never collides with the official tag
and every rebuild is newer than the previous customized build. Before the first release, add
`SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` as repository secrets using the certificate that
signed the installed custom app. A different certificate makes the installed app reject the
download. Do not relax `BundleSignature` to work around a mismatch.

The fork does not update the official Homebrew tap, dispatch the official website, or send official
Discord announcements. Release inputs pass through environment variables and must be a numeric
three-part base version and a known channel. The published tag targets the exact build commit, even
when a manual run selects a branch other than `main`.

Install
the first customized release manually. Later customized releases arrive through Check for Updates.
Do not install the upstream Homebrew cask over this fork: a bulk upgrade can replace Composer with
stock Tinycast. Removing that cask without `--zap` leaves bundle-specific user data in place.

A fork may be private. Its updater then needs a GitHub token that can read the repository's
contents, pasted once into Settings → General → Update token; see
[updates.md](features/updates.md). A private repository spends the account's Actions minutes on the
macOS release and test jobs.

A stable run then fans out to a second job, `universal`, which rebuilds the same commit with
`ARCHS="arm64 x86_64"` and attaches `Tinycast-Universal-<version>.dmg` / `.zip` to the release the
first job created, then bumps `tinycast-universal`. macOS 26 is the last release that boots on Intel,
and those Macs need both slices. Both jobs pin `ARCHS` explicitly and assert the slices on *every*
shipping binary — the app, `ClipboardTextHelper` and `Tinycast Dictation`: trusting `ARCHS_STANDARD` is what
shipped a thin arm64 build to Intel users once already, and it also keeps the Apple silicon download
from silently gaining a slice it never needs. A thin helper inside a universal app is the quiet form
of the same bug: the app boots on Intel and only clipboard OCR or dictation stops working.

Channel builds override `TINYCAST_BUNDLE_IDENTIFIER`, not the target-wide `PRODUCT_BUNDLE_IDENTIFIER`.
The Dictation helper derives its own identifier with a `.dictation` suffix; signature verification
checks that its bundle and signing identifiers agree and remain distinct from the main app.

### Release notes

`Scripts/release-notes.sh` composes the release body, and CI runs it just before `gh release create`.
It is safe to run by hand against any tag — it only reads:

```sh
CHANNEL=beta TAG=v0.9.13-beta.61 ./Scripts/release-notes.sh /tmp/body.md /tmp/discord.md
```

The changelog itself comes from GitHub's own release-notes API, which lists every merged PR with its
author and number — so contributors are credited without anyone maintaining a `CHANGELOG.md`, and
without Conventional Commits. **Nothing is ever committed to this repo**: the tag is created
server-side by `gh release create`, and no release, bot or version-bump commit exists.

Two details the script exists for:

- **The previous tag is picked per channel.** Beta and stable tags interleave on `main` — the same
  commit can carry both — so "the previous release" is only ever right within one channel. A stable
  release therefore spans every beta since the last stable.
- **The body is split by `<!-- tinycast:install -->`.** Everything above it is the changelog;
  everything below is the Homebrew and quarantine text, which only a download page needs. The update
  window cuts at that marker — see [features/updates.md](features/updates.md). Full PR URLs are
  shortened to `#304`, which still autolinks on the web and fits a 460pt window.

The Discord announcement carries the same changelog, truncated to fit Discord's component limit, and
pings `@everyone`.

### Homebrew tap automation

Each job's final step rewrites the `version` + `sha256` of its cask (`tinycast`, `tinycast@beta` or
`tinycast-universal`) in the [`homebrew-tinycast`](https://github.com/abue-ammar/homebrew-tinycast) tap
and pushes. It needs a `HOMEBREW_TAP_TOKEN` repo secret — a fine-grained PAT with **Contents:
read/write** on the tap repo. Without the secret the step logs a warning and skips; the release still
publishes. The `sed` is anchored to `^  version` / `^  sha256`, so a cask's two-space indent on those
lines is load-bearing.

Both stable casks install `Tinycast.app` under `com.tinycast.app`, so they `conflicts_with` one
another and Homebrew routes each Mac by `depends_on`: `tinycast` requires `arch: :arm64`, and
`tinycast-universal` takes the Intel Macs.
