#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
product_name="ECC Focus Mail Reader"
bundle_path="$HOME/Applications/$product_name.app"
support_dir="$HOME/Library/Application Support/ECC Focus Queue"
launch_agent="$HOME/Library/LaunchAgents/tools.ecc.focus-mail-reader.plist"
service="gui/$(/usr/bin/id -u)/tools.ecc.focus-mail-reader"

if [[ -e "$bundle_path" ]]; then
  /bin/rm -rf "$bundle_path"
fi

/usr/bin/osacompile -l JavaScript \
  -o "$bundle_path" \
  "$project_dir/Scripts/focus-queue-mail-reader.js"

info_plist="$bundle_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string tools.ecc.focus-mail-reader "$info_plist"
/usr/bin/plutil -replace CFBundleName -string "$product_name" "$info_plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$product_name" "$info_plist"
/usr/bin/plutil -replace NSAppleEventsUsageDescription -string \
  "ECC Focus Mail Reader runs a read-only local mail snapshot for the Focus Queue." \
  "$info_plist"

designated_requirement='=designated => identifier "tools.ecc.focus-mail-reader"'
/usr/bin/codesign --force --deep --sign - --requirements "$designated_requirement" "$bundle_path"
/usr/bin/codesign --verify --deep --strict "$bundle_path"

/bin/mkdir -p "$support_dir" "$HOME/Library/LaunchAgents"
/bin/rm -f "$launch_agent"
/usr/bin/plutil -create xml1 "$launch_agent"
/usr/bin/plutil -insert Label -string tools.ecc.focus-mail-reader "$launch_agent"
/usr/bin/plutil -insert ProgramArguments -json "[\"$bundle_path/Contents/MacOS/applet\"]" "$launch_agent"
/usr/bin/plutil -insert ProcessType -string Interactive "$launch_agent"
# The helper answers in under a second and exits. launchd's default 10-second
# throttle for short-lived jobs otherwise delays every paged mail request.
/usr/bin/plutil -insert ThrottleInterval -integer 1 "$launch_agent"
/usr/bin/plutil -insert WatchPaths -json \
  "[\"$support_dir/connector-commands/mail-request.json\"]" "$launch_agent"
/usr/bin/plutil -insert StandardOutPath -string "$support_dir/mail-reader.stdout.log" "$launch_agent"
/usr/bin/plutil -insert StandardErrorPath -string "$support_dir/mail-reader.stderr.log" "$launch_agent"

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

print -r -- "$bundle_path"
