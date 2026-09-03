#!/bin/zsh
set -euo pipefail

product_name="ECC Focus Queue"
installed_app="/Users/hira/Applications/$product_name.app"
desktop_launcher="/Users/hira/Desktop/$product_name.app"
launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue.plist"
service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue"
morning_launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue-morning.plist"
morning_service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue-morning"
mail_launch_agent="/Users/hira/Library/LaunchAgents/tools.ecc.focus-mail-reader.plist"
mail_service="gui/$(/usr/bin/id -u)/tools.ecc.focus-mail-reader"
mail_reader="/Users/hira/Applications/ECC Focus Mail Reader.app"
trash_dir="/Users/hira/.Trash/ECC Focus Queue uninstall $(/bin/date +%Y%m%d-%H%M%S)"

/bin/launchctl bootout "$service" 2>/dev/null || true
/bin/launchctl bootout "$morning_service" 2>/dev/null || true
/bin/launchctl bootout "$mail_service" 2>/dev/null || true
/usr/bin/pkill -x ECCFocusQueue 2>/dev/null || true
/bin/mkdir -p "$trash_dir"
if [[ -e "$installed_app" ]]; then
  /bin/mv "$installed_app" "$trash_dir/"
fi
if [[ -e "$launch_agent" ]]; then
  /bin/mv "$launch_agent" "$trash_dir/"
fi
if [[ -e "$morning_launch_agent" ]]; then
  /bin/mv "$morning_launch_agent" "$trash_dir/"
fi
if [[ -e "$mail_launch_agent" ]]; then
  /bin/mv "$mail_launch_agent" "$trash_dir/"
fi
if [[ -e "$mail_reader" ]]; then
  /bin/mv "$mail_reader" "$trash_dir/"
fi
if [[ -L "$desktop_launcher" ]]; then
  /bin/mv "$desktop_launcher" "$trash_dir/"
fi

print -r -- "Apps, Desktop launcher, and LaunchAgents moved to $trash_dir"
print -r -- "Local config, state, review records, and logs were preserved."
