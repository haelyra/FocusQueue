#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
support_dir="/Users/hira/Library/Application Support/ECC Focus Queue"
runtime_dir="$support_dir/ingestion"
automation_dir="$support_dir/automation"
automation_scripts="$automation_dir/Scripts"
automation_config="$automation_dir/Config"
local_bin_dir="/Users/hira/.local/bin"
launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue-morning.plist"
service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue-morning"

/bin/mkdir -p \
  "$runtime_dir" "$automation_scripts" "$automation_config" "$local_bin_dir" \
  "/Users/hira/Library/LaunchAgents"
for script in \
  focus_queue_morning.py focus_queue_codex.py focus_queue_mail.py \
  focus_queue_discord.py focus-queue-mail.js; do
  /bin/cp "$project_dir/Scripts/$script" "$automation_scripts/$script"
done
if [[ -f "$project_dir/Config/task-proposals.schema.json" ]]; then
  /bin/cp "$project_dir/Config/task-proposals.schema.json" "$automation_config/task-proposals.schema.json"
fi

/bin/rm -f \
  "$local_bin_dir/focus-mail" "$local_bin_dir/focus-discord" \
  "$local_bin_dir/focus-queue-codex"
print -r -- '#!/bin/sh' > "$local_bin_dir/focus-mail"
print -r -- "exec /usr/bin/python3 '$automation_scripts/focus_queue_mail.py' \"\$@\"" \
  >> "$local_bin_dir/focus-mail"
print -r -- '#!/bin/sh' > "$local_bin_dir/focus-discord"
print -r -- "exec /usr/bin/python3 '$automation_scripts/focus_queue_discord.py' \"\$@\"" \
  >> "$local_bin_dir/focus-discord"
print -r -- '#!/bin/sh' > "$local_bin_dir/focus-queue-codex"
print -r -- "exec /usr/bin/python3 '$automation_scripts/focus_queue_codex.py' \"\$@\"" \
  >> "$local_bin_dir/focus-queue-codex"
/bin/chmod 755 \
  "$local_bin_dir/focus-mail" "$local_bin_dir/focus-discord" \
  "$local_bin_dir/focus-queue-codex"

/bin/launchctl bootout "$service" 2>/dev/null || true
/bin/rm -f "$launch_agent"

print -r -- "$automation_dir"
