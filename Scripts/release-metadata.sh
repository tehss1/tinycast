#!/bin/bash
set -euo pipefail

if ! [[ "${BASE_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   ! [[ "${GITHUB_RUN_NUMBER:-}" =~ ^[0-9]+$ ]]; then
    echo "::error::Release version must be MAJOR.MINOR.PATCH and run number must be numeric."
    exit 1
fi
IFS=. read -r major minor patch <<< "$BASE_VERSION"
for number in "$major" "$minor" "$patch" "$GITHUB_RUN_NUMBER"; do
    if [ "${#number}" -gt 19 ] ||
       { [ "${#number}" -eq 19 ] && [[ "$number" > 9223372036854775807 ]]; }; then
        echo "::error::Release numbers must fit the updater's 64-bit version fields."
        exit 1
    fi
done
case "${CHANNEL:-}" in
    beta)
        suffix="-beta.${GITHUB_RUN_NUMBER}"
        display="Tinycast Beta"; bundle="com.tinycast.app.beta"; cask="tinycast@beta"; prerelease=true
        ;;
    stable)
        suffix=""
        if [ "$GITHUB_REPOSITORY" != "abue-ammar/tinycast" ]; then
            suffix="-composer.${GITHUB_RUN_NUMBER}"
        fi
        display="Tinycast"; bundle="com.tinycast.app"; cask="tinycast"; prerelease=false
        ;;
    *) echo "::error::Unknown release channel."; exit 1 ;;
esac
full="${BASE_VERSION}${suffix}"
{
    echo "full_version=${full}"
    echo "display_name=${display}"
    echo "bundle_id=${bundle}"
    echo "cask_name=${cask}"
    echo "dmg_file=Tinycast-${full}.dmg"
    echo "zip_file=Tinycast-${full}.zip"
    echo "prerelease=${prerelease}"
} >> "$1"
