#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tinycast-release-test.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
export GITHUB_RUN_NUMBER=12 BASE_VERSION=0.11.19 CHANNEL=stable GITHUB_REPOSITORY=tehss1/tinycast
"$root/Scripts/release-metadata.sh" "$scratch/fork"
grep -qx 'full_version=0.11.19-composer.12' "$scratch/fork"
grep -qx 'bundle_id=com.tinycast.app' "$scratch/fork"
grep -qx 'prerelease=false' "$scratch/fork"
GITHUB_REPOSITORY=abue-ammar/tinycast "$root/Scripts/release-metadata.sh" "$scratch/official"
grep -qx 'full_version=0.11.19' "$scratch/official"
CHANNEL=beta "$root/Scripts/release-metadata.sh" "$scratch/beta"
grep -qx 'full_version=0.11.19-beta.12' "$scratch/beta"
grep -qx 'bundle_id=com.tinycast.app.beta' "$scratch/beta"
grep -qx 'prerelease=true' "$scratch/beta"
for invalid in '' '00.11.19' '9223372036854775808.11.19' '0.11' '0.11.19-composer.12' '0.11.19"; touch sentinel; #' '$(touch sentinel)' $'0.11.19\nfull_version=99.0.0'; do
    if BASE_VERSION="$invalid" "$root/Scripts/release-metadata.sh" "$scratch/rejected" > "$scratch/rejected.log" 2>&1; then
        echo "Accepted invalid release version: $invalid"; exit 1
    fi
done
if CHANNEL=unknown "$root/Scripts/release-metadata.sh" "$scratch/rejected" > "$scratch/rejected.log" 2>&1 ||
   GITHUB_RUN_NUMBER=bad "$root/Scripts/release-metadata.sh" "$scratch/rejected" > "$scratch/rejected.log" 2>&1; then exit 1; fi
test ! -e "$scratch/rejected"
test ! -e sentinel
printf '%s\n' 'appintentsmetadataprocessor[1:2] warning: Metadata extraction skipped. No AppIntents.framework dependency found.' > "$scratch/build.log"
"$root/Scripts/check-build-warnings.sh" "$scratch/build.log"
for diagnostic in 'File.swift:1: warning: deprecated API' 'File.swift:1: error: invalid code'; do
    printf '%s\n' "$diagnostic" >> "$scratch/build.log"
    if "$root/Scripts/check-build-warnings.sh" "$scratch/build.log" > "$scratch/diagnostics.log"; then exit 1; fi
done
if "$root/Scripts/check-build-warnings.sh" "$scratch/missing.log"; then exit 1; fi
touch "$scratch/clean.log"
"$root/Scripts/check-build-warnings.sh" "$scratch/clean.log"
"$root/Scripts/check-composer-retention.sh"
mkdir -p "$scratch/repo/Scripts"
cp "$root/Scripts/check-composer-retention.sh" "$scratch/repo/Scripts/"
cp -R "$root/Tinycast" "$scratch/repo/"
cp "$root/project.yml" "$scratch/repo/"
git -C "$scratch/repo" init -q
# Git 2.54 repacks in the background after a commit, racing the cleanup trap's rm -rf.
git -C "$scratch/repo" config maintenance.auto false
git -C "$scratch/repo" config gc.auto 0
git -C "$scratch/repo" add .
git -C "$scratch/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm baseline
base="$(git -C "$scratch/repo" rev-parse HEAD)"
rm "$scratch/repo/Tinycast/Features/QuickActions/UI/ComposerToolbar.swift"
git -C "$scratch/repo" add -u
git -C "$scratch/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm upstream-deletion
if "$scratch/repo/Scripts/check-composer-retention.sh" "$base" > "$scratch/deletion.log" 2>&1; then exit 1; fi
coordinator=Tinycast/Features/QuickActions/UI/QuickActionCoordinator.swift
sed '/history.loadOnFirstUse()/d' "$root/$coordinator" > "$scratch/repo/$coordinator"
if "$scratch/repo/Scripts/check-composer-retention.sh" > "$scratch/ownership.log" 2>&1; then exit 1; fi
echo "Release metadata and Composer deletion/ownership regression fixtures passed."

# Run the shipped entry point with all external work confined to this fixture.
fixture="$scratch/network"
mkdir -p "$fixture/bin" "$fixture/Scripts" "$fixture/Tests"
cp "$root/Scripts/release-local.sh" "$root/Scripts/release-metadata.sh" "$fixture/Scripts/"
for script in check-composer-retention.sh run-tests.sh lint.sh verify-signature.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$fixture/Scripts/$script"
done
printf '#!/bin/bash\nexit 0\n' > "$fixture/Tests/release-pipeline-test.sh"
cat > "$fixture/Scripts/release-notes.sh" <<'STUB'
#!/bin/bash
printf 'Fixture notes\n' > "$1"
touch "$2"
STUB
cat > "$fixture/bin/network-command" <<'STUB'
#!/bin/bash
set -euo pipefail
command="${0##*/}"
key="$command $1"
if [ "$command" = gh ]; then key="$key ${2:-}"; fi
if [ "$command $1" = 'git ls-remote' ]; then key="$key $3"; fi
if [ "$command $1" = 'git fetch' ] && [[ "$*" = *automation/upstream-sync* ]]; then key='git fetch cleanup'; fi
if [ "$command $1" = 'git push' ] && [[ "$*" = *--delete* ]]; then key='git push delete'; fi
printf '%s\n' "$key" >> "$FIXTURE/calls"
if [ "$key" = "$TARGET" ]; then
    count=0
    [ ! -f "$FIXTURE/count" ] || read -r count < "$FIXTURE/count"
    count=$((count + 1))
    echo "$count" > "$FIXTURE/count"
    case "$MODE" in
        once)
            if [ "$count" -eq 1 ]; then
                echo partial-output-from-failed-attempt
                exit 128
            fi ;;

        always) exit 128 ;;
        cancel) kill -TERM "$PPID"; sleep 1; exit 143 ;;
        status) exit "$CANCEL_STATUS" ;;
        hang)
            echo "$$" >> "$FIXTURE/pids"
            perl -e '$SIG{TERM}="IGNORE"; sleep 60' &
            echo "$!" >> "$FIXTURE/pids"
            wait
            ;;
    esac
fi
case "$command $1" in
    'git branch') [[ "$*" != *--show-current* ]] || echo fixture ;;
    'git rev-parse') echo fixture-sha ;;
    'git ls-remote')
        if [ "$3" = --tags ] || [ "$MODE" = missing ]; then exit 2; fi ;;
    'gh api') echo v0.11.19 ;;
    'gh release')
        case "$2" in
            list) echo v0.11.18-composer.12 ;;
            view) echo https://example.invalid/release ;;
        esac ;;
esac
STUB
ln -s network-command "$fixture/bin/git"
ln -s network-command "$fixture/bin/gh"
cat > "$fixture/bin/xcodebuild" <<'STUB'
#!/bin/bash
if [ "$1" = -version ]; then echo 'Xcode fixture'; exit; fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = -derivedDataPath ]; then
        mkdir -p "$2/Build/Products/Release/Tinycast.app"
    fi
    shift
done
STUB
cat > "$fixture/bin/codesign" <<'STUB'
#!/bin/bash
case "$*" in
    *--extract-certificates=built*) echo fixture > built0 ;;
    *--extract-certificates=installed*) echo fixture > installed0 ;;
    *) echo 'Authority=Tinycast Self-Signed' >&2 ;;
esac
STUB
printf '#!/bin/bash\necho arm64\n' > "$fixture/bin/lipo"
printf '#!/bin/bash\necho '\''"Tinycast Self-Signed"'\''\n' > "$fixture/bin/security"
for command in xcodegen diskutil ditto; do
    printf '#!/bin/bash\nexit 0\n' > "$fixture/bin/$command"
done
chmod +x "$fixture/bin/"* "$fixture/Scripts/"* "$fixture/Tests/"*
run_network_fixture() {
    local target="$1" mode="$2" expected="$3" failure_step="${4:-}"
    rm -f "$fixture/count" "$fixture/calls" "$fixture/pids"
    local status=0
    PATH="$fixture/bin:$PATH" FIXTURE="$fixture" TARGET="$target" MODE="$mode" \
        TINYCAST_NETWORK_TIMEOUT=1 TINYCAST_NETWORK_RETRY_DELAYS='0 0' \
        "$fixture/Scripts/release-local.sh" > "$fixture/log" 2> "$fixture/stderr" || status=$?
    cat "$fixture/stderr" >> "$fixture/log"
    if [ "$status" -ne "$expected" ]; then cat "$fixture/log"; exit 1; fi
    if [ -n "$failure_step" ]; then
        grep -q "✗ Failed during: $failure_step" "$fixture/log"
    elif [ "$mode" = always ] && [ "$expected" -eq 0 ]; then
        grep -q 'Warning: release published' "$fixture/stderr"
        if grep -q '✗ Failed during:' "$fixture/log"; then exit 1; fi
        grep -q '✓ Released: https://github.com/tehss1/tinycast/releases/tag/v0.11.19-composer.13' "$fixture/log"
        if grep -q '^git push delete$' "$fixture/calls"; then exit 1; fi
    else
        grep -q '✓ Released: https://example.invalid/release' "$fixture/log"
    fi
}
for target in 'git fetch' 'gh api repos/abue-ammar/tinycast/releases/latest' 'gh release list' \
    'gh release view' 'git ls-remote --tags' 'git ls-remote --heads'; do
    run_network_fixture "$target" once 0
    grep -q 'attempt 2/3' "$fixture/log"
    if grep -q partial-output-from-failed-attempt "$fixture/log"; then exit 1; fi
done
run_network_fixture 'git fetch' always 1 'Checking the checkout'
test "$(cat "$fixture/count")" = 3
test "$(grep -c 'Network retry:' "$fixture/log")" = 2
run_network_fixture 'gh release list' always 1 'Finding the latest official release'
test "$(cat "$fixture/count")" = 3
run_network_fixture 'git ls-remote --tags' always 1 'Computing release metadata'
test "$(cat "$fixture/count")" = 3
for target in 'git ls-remote --heads' 'git fetch cleanup' 'gh release view'; do
    run_network_fixture "$target" always 0
    test "$(cat "$fixture/count")" = 3
done
for target in 'git fetch' 'gh api repos/abue-ammar/tinycast/releases/latest'; do
    started=$SECONDS
    if [ "$target" = 'git fetch' ]; then failure_step='Checking the checkout'
    else failure_step='Finding the latest official release'; fi
    run_network_fixture "$target" hang 1 "$failure_step"
    test "$(cat "$fixture/count")" = 3
    test "$((SECONDS - started))" -lt 15
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Timed-out network process survived: $pid"; exit 1
        fi
    done < "$fixture/pids"
done
run_network_fixture 'git ls-remote --heads' missing 0
test "$(cat "$fixture/count")" = 1
if grep -q '^git push delete$' "$fixture/calls"; then exit 1; fi
test "$(grep -c '^git ls-remote --tags$' "$fixture/calls")" = 1
if grep -q 'Network retry:' "$fixture/log"; then cat "$fixture/log"; exit 1; fi
for target in 'git push' 'gh release create' 'git push delete'; do
    case "$target" in
        'git push') failure_step='Fast-forwarding main' ;;
        'gh release create') failure_step='Publishing v' ;;
        *) failure_step='Cleaning up' ;;
    esac
    run_network_fixture "$target" always 1 "$failure_step"
    test "$(cat "$fixture/count")" = 1
    if grep -q 'Network retry:' "$fixture/log"; then cat "$fixture/log"; exit 1; fi
done
for target in 'git fetch' 'gh api repos/abue-ammar/tinycast/releases/latest'; do
    if [ "$target" = 'git fetch' ]; then failure_step='Checking the checkout'
    else failure_step='Finding the latest official release'; fi
    run_network_fixture "$target" cancel 1 "$failure_step"
    test "$(cat "$fixture/count")" = 1
    if grep -q 'Network retry:' "$fixture/log"; then exit 1; fi
    for CANCEL_STATUS in 129 130 143; do
        export CANCEL_STATUS
        run_network_fixture "$target" status 1 "$failure_step"
        test "$(cat "$fixture/count")" = 1
        if grep -q 'Network retry:' "$fixture/log"; then exit 1; fi
    done
done

# Signal only the owning bash while it waits on an owned network command.
for target in 'git fetch' 'gh api repos/abue-ammar/tinycast/releases/latest'; do
    for signal in TERM HUP INT; do
        rm -f "$fixture/count" "$fixture/calls" "$fixture/pids"
        # Perl resets INT inherited as ignored by asynchronous shell jobs.
        PATH="$fixture/bin:$PATH" FIXTURE="$fixture" TARGET="$target" MODE=hang \
            TINYCAST_NETWORK_TIMEOUT=30 TINYCAST_NETWORK_RETRY_DELAYS='0 0' \
            perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' /bin/bash \
            "$fixture/Scripts/release-local.sh" > "$fixture/log" 2>&1 &
        owner=$!
        for ((i=0; i<100; i++)); do
            if [ -f "$fixture/pids" ] && [ "$(wc -l < "$fixture/pids")" -ge 2 ]; then break; fi
            sleep 0.05
        done
        test -s "$fixture/pids"
        wrapper="$(ps -o ppid= -p "$(head -n1 "$fixture/pids")" | tr -d ' ')"
        kill -"$signal" "$owner"
        for ((i=0; i<40; i++)); do
            alive=false
            for pid in "$owner" "$wrapper" $(cat "$fixture/pids"); do
                if kill -0 "$pid" 2>/dev/null; then alive=true; fi
            done
            $alive || break
            sleep 0.05
        done
        if $alive; then cat "$fixture/log"; echo "Cancellation left a process alive ($signal, $target)"; exit 1; fi
        wait "$owner" && exit 1
        test "$(cat "$fixture/count")" = 1
        if grep -q 'Network retry:' "$fixture/log"; then exit 1; fi
        grep -q '✗ Failed during:' "$fixture/log"
    done
done
# Use a separate session to exercise Ctrl-C without signalling the test runner.
for phase in capture backoff tests build; do
    for signal in INT TERM; do
        rm -f "$fixture/count" "$fixture/calls" "$fixture/pids"
        target='gh api repos/abue-ammar/tinycast/releases/latest'
        mode=hang
        case "$phase" in
            backoff) mode=always ;;
            tests)
                target='network-command slow'
                printf '#!/bin/bash\nexec "$FIXTURE/bin/network-command" slow\n' > "$fixture/Scripts/run-tests.sh"
                ;;
            build)
                target='network-command build'
                cp "$fixture/bin/xcodebuild" "$fixture/bin/xcodebuild-original"
                printf '#!/bin/bash\nif [ "$1" = -version ]; then echo Xcode; exit; fi\nexec "$FIXTURE/bin/network-command" "$@"\n' > "$fixture/bin/xcodebuild"
                ;;
        esac
        PATH="$fixture/bin:$PATH" FIXTURE="$fixture" TARGET="$target" MODE="$mode" \
            TINYCAST_NETWORK_TIMEOUT=30 TINYCAST_NETWORK_RETRY_DELAYS='30 30' \
            perl -MPOSIX=setsid -e 'setsid() >= 0 or die $!; $SIG{INT}="DEFAULT"; exec @ARGV' \
            /bin/bash "$fixture/Scripts/release-local.sh" > "$fixture/log" 2>&1 &
        owner=$!
        ready=false
        for ((i=0; i<100; i++)); do
            if [ "$phase" = backoff ]; then
                if grep -q 'attempt 2/3 in 30s' "$fixture/log"; then ready=true; break; fi
            elif [ -f "$fixture/pids" ] && [ "$(wc -l < "$fixture/pids")" -ge 2 ]; then
                ready=true; break
            fi
            sleep 0.05
        done
        if ! $ready; then cat "$fixture/log"; echo "Cancellation fixture not ready ($phase)"; exit 1; fi
        sleep 0.1
        if [ "$phase" = backoff ]; then
            ps -axo pid=,ppid= | awk -v owner="$owner" '$2 == owner {print $1}' > "$fixture/pids"
        else
            ps -o ppid= -p "$(head -n1 "$fixture/pids")" >> "$fixture/pids"
        fi
        started=$SECONDS
        if [ "$signal" = INT ]; then kill -INT -- "-$owner"
        else kill -TERM "$owner"; fi
        for ((i=0; i<60; i++)); do
            alive=false
            for pid in "$owner" $(cat "$fixture/pids"); do
                if kill -0 "$pid" 2>/dev/null; then alive=true; fi
            done
            $alive || break
            sleep 0.05
        done
        if $alive; then cat "$fixture/log"; echo "Cancellation left a process alive ($signal, $phase)"; exit 1; fi
        wait "$owner" && exit 1
        test "$((SECONDS - started))" -lt 5
        grep -q '✗ Failed during:' "$fixture/log"
        if [ "$phase" = tests ]; then
            printf '#!/bin/bash\nexit 0\n' > "$fixture/Scripts/run-tests.sh"
        elif [ "$phase" = build ]; then
            mv "$fixture/bin/xcodebuild-original" "$fixture/bin/xcodebuild"
        fi
    done
done
echo 'Release network retry, timeout cleanup and single-attempt publication fixtures passed.'
