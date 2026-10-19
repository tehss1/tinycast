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
