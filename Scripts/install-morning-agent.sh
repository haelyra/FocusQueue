#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
support_dir="/Users/hira/Library/Application Support/ECC Focus Queue"
runtime_dir="$support_dir/ingestion"
launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue-morning.plist"
service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue-morning"

/bin/mkdir -p "$runtime_dir" "/Users/hira/Library/LaunchAgents"
/bin/rm -f "$launch_agent"
/usr/bin/plutil -create xml1 "$launch_agent"
/usr/bin/plutil -insert Label -string com.haelyra.ecc-focus-queue-morning "$launch_agent"
/usr/bin/plutil -insert ProgramArguments -json \
  "[\"/usr/bin/python3\",\"$project_dir/Scripts/focus_queue_morning.py\",\"run\",\"--config\",\"$support_dir/ingestion.json\",\"--runtime\",\"$runtime_dir\"]" \
  "$launch_agent"
/usr/bin/plutil -insert WorkingDirectory -string "/Users/hira/Documents/ECC" "$launch_agent"
/usr/bin/plutil -insert StartCalendarInterval -json '{"Hour":8,"Minute":0}' "$launch_agent"
/usr/bin/plutil -insert ProcessType -string Background "$launch_agent"
/usr/bin/plutil -insert StandardOutPath -string "$support_dir/morning.stdout.log" "$launch_agent"
/usr/bin/plutil -insert StandardErrorPath -string "$support_dir/morning.stderr.log" "$launch_agent"

/bin/launchctl bootout "$service" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$launch_agent"

print -r -- "$launch_agent"
