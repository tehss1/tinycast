#!/bin/bash
set -euo pipefail
test -f "$1" && test -r "$1"

if grep -E 'warning:|error:' "$1" |
   grep -Ev 'appintentsmetadataprocessor\[[0-9]+:[0-9]+\] warning: Metadata extraction skipped\. No AppIntents\.framework dependency found\.$'; then
    exit 1
fi
