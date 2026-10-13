#!/bin/bash
set -euo pipefail
if [ ! -f "$1" ] || [ ! -r "$1" ]; then exit 1; fi

if grep -E 'warning:|error:' "$1" |
   grep -Ev 'appintentsmetadataprocessor\[[0-9]+:[0-9]+\] warning: Metadata extraction skipped\. No AppIntents\.framework dependency found\.$'; then
    exit 1
fi
