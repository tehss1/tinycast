#!/bin/bash
# Follow the latest official release and publish it as a Composer stable build from this Mac.
# Usage: ./Scripts/release-local.sh [--dry-run] [--release-main]
# A local port of sync-upstream.yml and release.yml's `build` job, for a fork without Actions.
# Exit 0: released, or nothing to do. 1: a step failed. 2: the merge conflicts; it is left in place.
# --release-main publishes main's own changes when upstream has nothing new.
set -euo pipefail

FORK_REPO="tehss1/tinycast"
UPSTREAM_REPO="abue-ammar/tinycast"
SYNC_BRANCH="automation/upstream-sync"
IDENTITY="Tinycast Self-Signed"
DISPLAY_NAME="Tinycast"
BUNDLE_ID="com.tinycast.app"
CASK="tinycast"
INSTALLED_APP="/Applications/Tinycast.app"
GIT_NAME="tehss1"
GIT_EMAIL="62029692+tehss1@users.noreply.github.com"

# Xcode prints it for a target without App Intents; check-build-warnings.sh allows it too.
# Xcode 26 ends it "skipped. No AppIntents…", Xcode 27 "skipped, no AppIntents…".
APP_INTENTS_NOTICE='appintentsmetadataprocessor\[[0-9]+:[0-9]+\] warning: Metadata extraction skipped[.,]'
DRY_RUN=false
RELEASE_MAIN=false
STEP="setup"
CONFLICT=false
SCRATCH=""
START_BRANCH=""

step() {
    STEP="$1"
    printf '\n\033[1m==> %s\033[0m\n' "$1"
}

die() {
    echo "✗ $1" >&2
    exit 1
}

# Wait in bash so a signal can terminate and reap the owned command group.
run_interruptible() {
    local timeout="$1" output="$2" status=0
    shift 2
    perl -MPOSIX=setpgid,WNOHANG -e '
        use strict;
        use warnings;
        use Time::HiRes qw(time sleep);
        my $path = shift @ARGV;
        my $output;
        if (length $path) { open $output, ">", $path or die "output: $!"; }
        my $seconds = shift @ARGV;
        my $owner = shift @ARGV;
        my $parent = getppid();
        my $pid = fork();
        defined $pid or die "fork: $!";
        if (!$pid) {
            setpgid(0, 0) == 0 or die "setpgid: $!";
            if ($output) {
                open STDOUT, ">&", $output or die "stdout: $!";
                if (!$seconds) { open STDERR, ">&", $output or die "stderr: $!"; }
            }
            exec @ARGV;
            die "exec: $!";
        }
        setpgid($pid, $pid);
        my $stop = sub {
            my $discard = shift;
            $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE";
            kill "TERM", -$pid;
            my $until = time() + 3;
            my $reaped = 0;
            while (1) {
                if (!$reaped) {
                    my $done = waitpid($pid, WNOHANG);
                    $reaped = 1 if $done == $pid || $done == -1;
                }
                last if !kill(0, -$pid) || time() >= $until;
                sleep 0.05;
            }
            kill "KILL", -$pid if kill(0, -$pid);
            waitpid($pid, 0) unless $reaped;
            unlink $path if $discard && $seconds && length $path;
        };
        $SIG{HUP} = sub { $stop->(1); exit 129; };
        $SIG{INT} = sub { $stop->(1); exit 130; };
        $SIG{TERM} = sub { $stop->(1); exit 143; };
        my $deadline = time() + $seconds;
        my $status;
        while (1) {
            if (getppid() != $parent || !kill(0, $owner)) {
                $stop->(1); exit 143;
            }
            my $done = waitpid($pid, WNOHANG);
            if ($done == $pid) { $status = $?; last; }
            if ($seconds && time() >= $deadline) { $stop->(1); exit 124; }
            sleep 0.05;
        }
        $stop->() if kill(0, -$pid);
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$output" "$timeout" "$$" "$@" &
    NETWORK_PID=$!
    wait_interruptible || status=$?
    return "$status"
}

wait_interruptible() {
    local status=0
    trap 'cancel_network 129' HUP
    trap 'cancel_network 130' INT
    trap 'cancel_network 143' TERM
    wait "$NETWORK_PID" || status=$?
    NETWORK_PID=""
    trap - INT TERM HUP
    return "$status"
}

# Each attempt owns a process group so git transport helpers cannot outlive its deadline.
with_network_retry() {
    NETWORK_OUTPUT=""
    local attempt status delay timeout="${TINYCAST_NETWORK_TIMEOUT:-120}"
    local delays="${TINYCAST_NETWORK_RETRY_DELAYS:-15 45}" first_delay second_delay extra
    read -r first_delay second_delay extra <<< "$delays"
    [[ "$timeout" =~ ^[1-9][0-9]*$ && "${first_delay:-}" =~ ^[0-9]+$ &&
        "${second_delay:-}" =~ ^[0-9]+$ && -z "$extra" ]] ||
        die "Invalid network timeout or retry delays"
    NETWORK_FILE="$(mktemp "${TMPDIR:-/tmp}/tinycast-network.XXXXXXXX")"
    for attempt in 1 2 3; do
        if GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}" \
            GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-30}" \
            run_interruptible "$timeout" "$NETWORK_FILE" "$@"; then
            NETWORK_OUTPUT="$(cat "$NETWORK_FILE")"
            rm -f "$NETWORK_FILE"
            return 0
        else
            status=$?
        fi
        case "$status" in 129|130|143) rm -f "$NETWORK_FILE"; return "$status" ;; esac
        # ls-remote exit 2 means no matching ref, not an unavailable server.
        if [ "$1" = git ] && [ "${2:-}" = ls-remote ] &&
            [ "$status" -ne 128 ] && [ "$status" -ne 124 ]; then
            rm -f "$NETWORK_FILE"
            return "$status"
        fi
        if [ "$attempt" -eq 3 ]; then
            rm -f "$NETWORK_FILE"
            return "$status"
        fi
        delay="$first_delay"
        [ "$attempt" -eq 1 ] || delay="$second_delay"
        printf 'Network retry: %s %s failed (%s); attempt %s/3 in %ss\n' \
            "$1" "${2:-}" "$status" "$((attempt + 1))" "$delay" >&2
        sleep "$delay" &
        NETWORK_PID=$!
        wait_interruptible
    done
}

cancel_network() {
    local status="$1"
    trap '' INT TERM HUP
    if [ -n "${NETWORK_PID:-}" ]; then
        kill -TERM "$NETWORK_PID" 2>/dev/null || true
        wait "$NETWORK_PID" 2>/dev/null || true
    fi
    [ -z "${NETWORK_FILE:-}" ] || rm -f "$NETWORK_FILE"
    exit "$status"
}

# The whole log is in the scratch dir, which goes away; print what a reader needs first.
show_log() {
    local log="$1"
    echo "--- errors in ${log##*/} ---" >&2
    grep -E '(^|: )error: |\*\* BUILD FAILED \*\*' "$log" | head -n 40 >&2 || true
    echo "--- last 40 lines of ${log##*/} ---" >&2
    tail -n 40 "$log" >&2
}

finish() {
    local status=$?
    [ -z "${NETWORK_FILE:-}" ] || rm -f "$NETWORK_FILE"
    if [ -n "$SCRATCH" ]; then
        git worktree remove --force "$SCRATCH/baseline" 2>/dev/null || true
        rm -rf "$SCRATCH"
        git worktree prune
    fi
    if [ "$CONFLICT" = true ]; then
        exit 2
    fi
    if [ "$status" -ne 0 ]; then
        echo "✗ Failed during: ${STEP}" >&2
        status=1
    fi
    # Put the checkout back where it started, unless a conflict is waiting on the sync branch.
    if [ -n "$START_BRANCH" ] && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
        git switch --quiet "$START_BRANCH" 2>/dev/null || true
    fi
    exit "$status"
}

select_xcode() {
    if [ -z "${DEVELOPER_DIR:-}" ]; then
        local xcode
        xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n1)"
        [ -n "$xcode" ] || die "No Xcode found in /Applications"
        export DEVELOPER_DIR="$xcode/Contents/Developer"
    fi
    echo "Using $(xcodebuild -version | head -n1) at $DEVELOPER_DIR"
}

# Prints warnings without line numbers or the checkout path, so two trees compare line for line.
debug_build_warnings() {
    local tree="$1" derived="$2" log="$3"
    if ! run_interruptible 0 "$log" xcodebuild build -project "$tree/Tinycast.xcodeproj" -scheme Tinycast \
        -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO; then
        show_log "$log"
        return 1
    fi
    BUILD_WARNINGS="$({ grep -E 'warning:' "$log" | grep -Ev "$APP_INTENTS_NOTICE" || true; } |
        sed -E -e "s|${tree}/||g" -e "s|${derived}/||g" -e 's|(:[0-9]+){1,2}: warning:|: warning:|' \
            -e 's|^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+ ||' -e 's|\[[0-9]+:[0-9]+\]||' |
        sort -u)"
}

main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --release-main) RELEASE_MAIN=true ;;
            *) echo "usage: $0 [--dry-run] [--release-main]" >&2; exit 1 ;;
        esac
    done

    cd "$(dirname "$0")/.."
    local repo
    repo="$(pwd -P)"
    trap finish EXIT

    step "Checking the checkout"
    if [ -n "$(git status --porcelain --untracked-files=no)" ] || [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
        git status --short --untracked-files=no >&2
        die "The working tree has uncommitted changes or an unfinished merge"
    fi
    START_BRANCH="$(git branch --show-current)"
    with_network_retry git fetch --quiet --tags origin
    select_xcode
    command -v xcodegen >/dev/null || die "xcodegen not found: brew install xcodegen"
    security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" ||
        die "'$IDENTITY' is not in the keychain (docs/signing.md)"
    $DRY_RUN && echo "Dry run: nothing will be pushed or published."

    # Releases, not `main`: the fork only ever ships code the official project has published.
    step "Finding the latest official release"
    local tag
    with_network_retry gh api "repos/${UPSTREAM_REPO}/releases/latest" --jq .tag_name
    tag="$NETWORK_OUTPUT"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unexpected official release tag '$tag'"
    with_network_retry git fetch --quiet --no-tags "https://github.com/${UPSTREAM_REPO}.git" \
        "refs/tags/${tag}:refs/upstream/${tag}"
    # Drafts still claim their number, but only a published release counts as shipped.
    local releases published released=false merged=true
    with_network_retry gh release list -R "$FORK_REPO" --limit 1000 --json tagName --jq '.[].tagName'
    releases="$NETWORK_OUTPUT"
    with_network_retry gh release list -R "$FORK_REPO" --exclude-drafts --limit 1000 --json tagName \
        --jq '.[].tagName'
    published="$NETWORK_OUTPUT"
    grep -q "^${tag}-composer\." <<< "$published" && released=true
    git merge-base --is-ancestor "refs/upstream/${tag}" origin/main && merged=true || merged=false
    echo "Official release: ${tag} (on main: ${merged}, Composer release exists: ${released})"

    if [ "$merged" = true ] && [ "$released" = true ]; then
        if $RELEASE_MAIN; then
            local latest
            latest="$(grep -E -- '-composer\.[0-9]+$' <<< "$published" |
                sort -t. -k4,4n | tail -n1)"
            if [ "$(git rev-parse --quiet --verify "refs/tags/${latest}^{commit}")" = \
                "$(git rev-parse origin/main)" ] && ! $DRY_RUN; then
                echo "Nothing to do: main is already released as ${latest}."
                exit 0
            fi
            echo "Nothing new upstream; --release-main publishes the current main (last: ${latest})."
        elif ! $DRY_RUN; then
            echo "Nothing to do: ${tag} is already on main and released as a Composer build."
            exit 0
        else
            echo "Nothing new upstream; the dry run rebuilds the current main instead."
        fi
    fi

    step "Merging ${tag} into ${SYNC_BRANCH}"
    # A rerun after a resolved conflict continues from the commit that resolved it.
    if [ "$START_BRANCH" = "$SYNC_BRANCH" ] &&
        git merge-base --is-ancestor "refs/upstream/${tag}" HEAD &&
        git merge-base --is-ancestor origin/main HEAD; then
        echo "Resuming from $(git rev-parse --short HEAD) on ${SYNC_BRANCH}"
    else
        git switch --quiet -C "$SYNC_BRANCH" origin/main
        if [ "$merged" = true ]; then
            echo "${tag} is already on main; building origin/main as is."
        elif ! git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" merge --no-edit \
            -m "Merge Tinycast ${tag} while preserving Composer" "refs/upstream/${tag}"; then
            CONFLICT=true
            echo "✗ Merging ${tag} conflicts in:" >&2
            git diff --name-only --diff-filter=U | sed 's/^/    /' >&2
            echo "The merge is left in place on ${SYNC_BRANCH}. Resolve it, commit, and rerun" >&2
            echo "this script from that branch to verify and release it." >&2
            exit 2
        fi
    fi
    local sha
    sha="$(git rev-parse HEAD)"

    step "Checking that Composer survived the merge"
    ./Scripts/check-composer-retention.sh origin/main

    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tinycast-release.XXXXXX")"
    SCRATCH="$(cd "$SCRATCH" && pwd -P)"
    echo "Scratch directory: $SCRATCH"

    step "Checking the generated Xcode project is committed"
    xcodegen generate --quiet
    if ! git diff --quiet -- Tinycast.xcodeproj; then
        git diff --stat -- Tinycast.xcodeproj >&2
        git checkout -- Tinycast.xcodeproj
        die "Tinycast.xcodeproj differs from what project.yml generates"
    fi
    echo "✓ Tinycast.xcodeproj matches project.yml"

    step "Checking Composer retention and release fixtures"
    run_interruptible 0 "" ./Tests/release-pipeline-test.sh

    step "Running the test suite"
    run_interruptible 0 "" ./Scripts/run-tests.sh

    step "Linting"
    run_interruptible 0 "" ./Scripts/lint.sh

    step "Checking model imports"
    if grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/; then
        die "A Model layer imports a UI framework"
    fi
    echo "✓ No Model layer imports AppKit, SwiftUI or Cocoa"

    step "Building Debug with no new warnings"
    local warnings baseline_warnings new_warnings
    debug_build_warnings "$repo" "$SCRATCH/DerivedData-Debug" "$SCRATCH/debug.log"
    warnings="$BUILD_WARNINGS"
    if [ "$(git rev-parse HEAD^{tree})" = "$(git rev-parse origin/main^{tree})" ]; then
        echo "Same tree as origin/main, so no warning can be new."
        baseline_warnings="$warnings"
    else
        echo "Building origin/main for the baseline warnings"
        git worktree add --quiet --detach "$SCRATCH/baseline" origin/main
        debug_build_warnings "$SCRATCH/baseline" \
            "$SCRATCH/DerivedData-Baseline" "$SCRATCH/baseline.log"
        baseline_warnings="$BUILD_WARNINGS"
    fi
    new_warnings="$(comm -13 <(printf '%s\n' "$baseline_warnings") <(printf '%s\n' "$warnings") |
        sed '/^$/d')"
    if [ -n "$new_warnings" ]; then
        printf '%s\n' "$new_warnings" >&2
        die "The Debug build has new warnings"
    fi
    echo "✓ Debug build: $(printf '%s' "$warnings" | grep -c . || true) warnings, none new"

    # Not forced: a `main` that moved since the merge fails here instead of losing commits.
    step "Fast-forwarding main"
    if $DRY_RUN; then
        echo "Dry run: would run git push origin ${SYNC_BRANCH}:main"
    else
        git push origin "${SYNC_BRANCH}:main"
    fi

    # N goes one past every Composer build ever published, whatever its base version.
    step "Computing release metadata"
    local build_number full_version release_tag dmg_file zip_file meta="$SCRATCH/metadata"
    build_number="$(grep -oE -- '-composer\.[0-9]+$' <<< "$releases" | cut -d. -f2 | sort -n |
        tail -n1)"
    build_number=$((${build_number:-0} + 1))
    GITHUB_RUN_NUMBER="$build_number" GITHUB_REPOSITORY="$FORK_REPO" CHANNEL=stable \
        BASE_VERSION="${tag#v}" ./Scripts/release-metadata.sh "$meta"
    full_version="$(sed -n 's/^full_version=//p' "$meta")"
    dmg_file="$(sed -n 's/^dmg_file=//p' "$meta")"
    zip_file="$(sed -n 's/^zip_file=//p' "$meta")"
    [ "$(sed -n 's/^display_name=//p' "$meta")" = "$DISPLAY_NAME" ] &&
        [ "$(sed -n 's/^bundle_id=//p' "$meta")" = "$BUNDLE_ID" ] ||
        die "release-metadata.sh no longer describes the ${DISPLAY_NAME} stable channel"
    release_tag="v${full_version}"
    if with_network_retry git ls-remote --exit-code --tags origin "refs/tags/${release_tag}" >/dev/null; then
        die "Tag ${release_tag} already exists on origin"
    else
        local remote_status=$?
        [ "$remote_status" -eq 2 ] || return "$remote_status"
    fi
    echo "Version ${full_version}, build ${build_number}, from ${sha}"

    step "Building the signed Release app"
    local derived="$SCRATCH/DerivedData" app
    app="$SCRATCH/DerivedData/Build/Products/Release/${DISPLAY_NAME}.app"
    # ARCHS pinned to what this channel has always shipped (compat/README.md).
    if ! run_interruptible 0 "$SCRATCH/release.log" xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
        -derivedDataPath "$derived" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
        PRODUCT_NAME="$DISPLAY_NAME" TINYCAST_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        TINYCAST_UPDATE_REPOSITORY="$FORK_REPO" \
        MARKETING_VERSION="$full_version" CURRENT_PROJECT_VERSION="$build_number" \
        build; then
        show_log "$SCRATCH/release.log"
        die "The Release build failed"
    fi
    echo "✓ $app"

    step "Asserting the build is arm64-only"
    local bin slices
    for bin in "$app/Contents/MacOS/${DISPLAY_NAME}" "$app/Contents/Helpers/ClipboardTextHelper" \
        "$app/Contents/Helpers/Tinycast Dictation.app/Contents/MacOS/Tinycast Dictation"; do
        slices="$(lipo -archs "$bin")"
        [ "$slices" = "arm64" ] || die "${bin##*/}: expected arm64 alone, got '$slices'"
    done
    echo "✓ arm64 only"

    step "Asserting the signature is notarizable"
    ./Scripts/verify-signature.sh "$app"

    # The in-app updater refuses a bundle whose leaf certificate differs from the running app's.
    step "Checking the signing certificate"
    local authority built_leaf installed_leaf
    authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n1)"
    [ "$authority" = "$IDENTITY" ] || die "Signed by '$authority', not '$IDENTITY'"
    mkdir "$SCRATCH/certs"
    (cd "$SCRATCH/certs" && codesign -d --extract-certificates=built "$app" 2>/dev/null)
    built_leaf="$(shasum -a 256 "$SCRATCH/certs/built0" | cut -d' ' -f1)"
    if [ -d "$INSTALLED_APP" ]; then
        (cd "$SCRATCH/certs" && codesign -d --extract-certificates=installed "$INSTALLED_APP" 2>/dev/null)
        installed_leaf="$(shasum -a 256 "$SCRATCH/certs/installed0" | cut -d' ' -f1)"
        [ "$built_leaf" = "$installed_leaf" ] ||
            die "Leaf certificate ${built_leaf} differs from ${INSTALLED_APP}'s ${installed_leaf}"
        echo "✓ Signed by ${IDENTITY}; leaf certificate matches ${INSTALLED_APP} (${built_leaf})"
    else
        echo "✓ Signed by ${IDENTITY} (${built_leaf}); ${INSTALLED_APP} is not installed to compare"
    fi

    # `ditto -c -k --keepParent --sequesterRsrc` is the only zip that leaves the signature verifiable.
    step "Packaging the DMG and ZIP"
    local stage="$SCRATCH/stage" dist="$SCRATCH/dist"
    mkdir -p "$stage" "$dist"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    diskutil image create from "$stage" --format UDZO --volumeName "$DISPLAY_NAME" "$dist/$dmg_file"
    ditto -c -k --keepParent --sequesterRsrc "$app" "$dist/$zip_file"
    ls -lh "$dist"

    # A dry run's merge was never pushed, and GitHub cannot generate notes for a commit it lacks.
    step "Composing release notes"
    local notes_sha="$sha"
    if $DRY_RUN && ! git branch -r --contains "$sha" | grep -q 'origin/main$'; then
        notes_sha="$(git rev-parse origin/main)"
        echo "Dry run: ${sha} is not on origin, so the notes are generated against ${notes_sha}"
    fi
    REPO="$FORK_REPO" CHANNEL=stable TAG="$release_tag" SHA="$notes_sha" VERSION="$full_version" \
        DISPLAY_NAME="$DISPLAY_NAME" BUNDLE_ID="$BUNDLE_ID" CASK="$CASK" \
        ./Scripts/release-notes.sh "$SCRATCH/notes.md" "$SCRATCH/changelog.md"

    # --notes-file, never --generate-notes: gh would put the install text above the changelog.
    step "Publishing ${release_tag}"
    if $DRY_RUN; then
        echo "--- notes.md ---"
        cat "$SCRATCH/notes.md"
        echo "----------------"
        echo "Dry run: would create release ${release_tag} at ${sha} with ${dmg_file} and ${zip_file}"
        echo "✓ Dry run complete"
        exit 0
    fi
    gh release create "$release_tag" "$dist/$dmg_file" "$dist/$zip_file" -R "$FORK_REPO" \
        --target "$sha" --title "${DISPLAY_NAME} ${full_version}" --notes-file "$SCRATCH/notes.md"

    step "Cleaning up"
    git switch --quiet main
    git merge --quiet --ff-only "$sha" || echo "Local main has diverged; it was not fast-forwarded."
    git branch --quiet -D "$SYNC_BRANCH"
    local cleanup_ok=true delete_remote=false release_url known_url
    known_url="https://github.com/${FORK_REPO}/releases/tag/${release_tag}"
    if with_network_retry gh release view "$release_tag" -R "$FORK_REPO" --json url --jq .url; then
        release_url="$NETWORK_OUTPUT"
    else
        echo "Warning: release published; URL lookup failed; using the known release URL." >&2
        cleanup_ok=false
    fi
    if with_network_retry git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null; then
        if with_network_retry git fetch --quiet origin "$SYNC_BRANCH"; then
            if git merge-base --is-ancestor FETCH_HEAD "$sha"; then
                delete_remote=true
            fi
        else
            echo "Warning: release published; cleanup fetch failed; keeping remote sync branch." >&2
            cleanup_ok=false
        fi
    else
        remote_status=$?
        if [ "$remote_status" -ne 2 ]; then
            echo "Warning: release published; cleanup ref lookup failed; keeping remote sync branch." >&2
            cleanup_ok=false
        fi
    fi
    if $cleanup_ok; then
        if $delete_remote; then git push --quiet origin --delete "$SYNC_BRANCH"; fi
    else
        release_url="$known_url"
    fi
    START_BRANCH="main"
    echo "✓ Released: $release_url"
}

# Parsed whole before it runs, so switching branches under the script cannot change it mid-run.
main "$@"
exit
