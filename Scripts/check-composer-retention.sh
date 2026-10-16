#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

require() {
    if ! grep -Fq "$2" "$1"; then
        echo "::error::Composer retention check failed: $1 must retain $2"
        exit 1
    fi
}
require Tinycast/App/AppCore.swift 'rewriteHistory.loadWithoutWaitingForKeychain()'
require Tinycast/App/AppCore.swift 'quickActionCoordinator'
require Tinycast/Features/QuickActions/UI/QuickActionCoordinator.swift 'composerModel'
require Tinycast/Features/QuickActions/Service/RewriteHistoryStore.swift 'AES.GCM.open'
require Tinycast/Features/QuickActions/Service/RewriteHistoryKey.swift 'KeychainSecretStore'
require Tinycast/Features/Updates/Model/ReleaseFeed.swift 'fallbackRepository = "tehss1/tinycast"'
require project.yml 'TINYCAST_UPDATE_REPOSITORY: "tehss1/tinycast"'

if [ -n "${1:-}" ]; then
    deleted="$(git diff --name-only --diff-filter=D "$1" HEAD -- Tinycast/Features/QuickActions)"
    if [ -n "$deleted" ]; then
        echo "::error::An upstream merge removed Composer files; review it manually: $deleted"
        exit 1
    fi
fi
echo "Composer source, ownership, encryption and fork feed retained."
