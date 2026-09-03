#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
product_name="ECC Focus Queue"
built_app="$project_dir/dist/$product_name.app"
install_dir="/Users/hira/Applications"
installed_app="$install_dir/$product_name.app"
desktop_dir="/Users/hira/Desktop"
desktop_launcher="$desktop_dir/$product_name.app"
support_dir="/Users/hira/Library/Application Support/$product_name"
local_bin_dir="/Users/hira/.local/bin"
launch_agent="/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue.plist"
service="gui/$(/usr/bin/id -u)/com.haelyra.ecc-focus-queue"
mail_reader_app="/Users/hira/Applications/ECC Focus Mail Reader.app"
mail_reader_launch_agent="/Users/hira/Library/LaunchAgents/tools.ecc.focus-mail-reader.plist"

if [[ "${1:-}" != "--no-build" ]]; then
  "$script_dir/build-app.sh" >/dev/null
fi

/bin/mkdir -p "$install_dir" "$desktop_dir" "$support_dir" "$local_bin_dir" "/Users/hira/Library/LaunchAgents"
/usr/bin/pkill -x ECCFocusQueue 2>/dev/null || true
if [[ -e "$installed_app" ]]; then
  /bin/rm -rf "$installed_app"
fi
/usr/bin/ditto "$built_app" "$installed_app"
/bin/cp "$installed_app/Contents/MacOS/focus-queue-session" "$local_bin_dir/focus-queue-session"

if [[ ! -e "$desktop_launcher" && ! -L "$desktop_launcher" ]]; then
  /bin/ln -s "$installed_app" "$desktop_launcher"
elif [[ ! -L "$desktop_launcher" ]]; then
  print -u2 -r -- "Desktop item already exists and was left unchanged: $desktop_launcher"
fi

if [[ ! -e "$support_dir/config.json" ]]; then
  /bin/cp "$project_dir/Config/ecc.config.json" "$support_dir/config.json"
fi

/bin/rm -f "$launch_agent"
/usr/bin/plutil -create xml1 "$launch_agent"
/usr/bin/plutil -insert Label -string com.haelyra.ecc-focus-queue "$launch_agent"
/usr/bin/plutil -insert ProgramArguments -json "[\"$installed_app/Contents/MacOS/ECCFocusQueue\"]" "$launch_agent"
/usr/bin/plutil -insert RunAtLoad -bool true "$launch_agent"
/usr/bin/plutil -insert ProcessType -string Interactive "$launch_agent"
/usr/bin/plutil -insert StandardOutPath -string "$support_dir/launch.stdout.log" "$launch_agent"
/usr/bin/plutil -insert StandardErrorPath -string "$support_dir/launch.stderr.log" "$launch_agent"

/bin/launchctl bootout "$service" 2>/dev/null || true
/bin/sleep 1
bootstrapped=0
for attempt in 1 2 3 4 5; do
  if /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$launch_agent" 2>/dev/null; then
    bootstrapped=1
    break
  fi
  /bin/sleep 1
done
if [[ "$bootstrapped" -ne 1 ]]; then
  print -u2 -r -- "Could not bootstrap $launch_agent after five attempts."
  exit 1
fi
/bin/launchctl kickstart -k "$service"

if [[ ! -d "$mail_reader_app" || ! -f "$mail_reader_launch_agent" ]]; then
  "$script_dir/install-mail-reader.sh" >/dev/null
fi
"$script_dir/install-morning-agent.sh" >/dev/null

print -r -- "$installed_app"
print -r -- "$desktop_launcher"
