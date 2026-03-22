#!/bin/bash
# Deploy somewm-one config to ~/.config/somewm
# Usage: ./deploy.sh [--dry-run]
#
# This copies the somewm-one project from the repo to the active config.
# Run after editing rc.lua or themes in plans/somewm-one/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.config/somewm"

if [[ "${1:-}" == "--dry-run" ]]; then
    echo "Dry run — would sync:"
    rsync -av --delete --exclude 'deploy.sh' --dry-run "$SCRIPT_DIR/" "$TARGET/"
    exit 0
fi

# Backup current config timestamp
if [[ -f "$TARGET/rc.lua" ]]; then
    echo "Backing up current rc.lua -> rc.lua.bak"
    cp "$TARGET/rc.lua" "$TARGET/rc.lua.bak"
fi

# Sync (exclude deploy.sh itself)
rsync -av --delete --exclude 'deploy.sh' "$SCRIPT_DIR/" "$TARGET/"

echo ""
echo "Deployed somewm-one to $TARGET"
echo "Reload: somewm-client reload"
echo "   or:  Super+Ctrl+r (if bound)"
