#!/bin/zsh
set -euo pipefail

product_name="ECC Focus Queue"
installed_app="/Users/hira/Applications/$product_name.app"
launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue.plist"
service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue"
trash_dir="/Users/hira/.Trash/ECC Focus Queue uninstall $(/bin/date +%Y%m%d-%H%M%S)"

/bin/launchctl bootout "$service" 2>/dev/null || true
/usr/bin/pkill -x ECCFocusQueue 2>/dev/null || true
/bin/mkdir -p "$trash_dir"
if [[ -e "$installed_app" ]]; then
  /bin/mv "$installed_app" "$trash_dir/"
fi
if [[ -e "$launch_agent" ]]; then
  /bin/mv "$launch_agent" "$trash_dir/"
fi

print -r -- "App and LaunchAgent moved to $trash_dir"
print -r -- "Local config, state, review records, and logs were preserved."
