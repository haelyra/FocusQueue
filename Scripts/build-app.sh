#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
product_name="Focus Queue"
release_bundle="$project_dir/dist/$product_name.app"
build_dir="${ECC_FOCUS_QUEUE_BUILD_DIR:-$project_dir/.build}"
executable_path="$build_dir/release/ECCFocusQueue"
session_helper_path="$build_dir/release/focus-queue-session"
map_helper_path="$build_dir/release/focus-queue-map"

swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release

/bin/mkdir -p "$project_dir/dist"
staging_dir=$(/usr/bin/mktemp -d "$project_dir/dist/.bundle-stage.XXXXXX")
bundle_path="$staging_dir/$product_name.app"
/bin/mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
/bin/cp "$executable_path" "$bundle_path/Contents/MacOS/ECCFocusQueue"
/bin/cp "$session_helper_path" "$bundle_path/Contents/MacOS/focus-queue-session"
/bin/cp "$map_helper_path" "$bundle_path/Contents/MacOS/focus-queue-map"
/bin/cp "$project_dir/Config/config.example.json" "$bundle_path/Contents/Resources/config.example.json"
/bin/cp "$project_dir/Config/CODEX_GLOBAL_INSTRUCTIONS.md" "$bundle_path/Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md"
/bin/cp "$project_dir/Config/CLAUDE_GLOBAL_INSTRUCTIONS.md" "$bundle_path/Contents/Resources/CLAUDE_GLOBAL_INSTRUCTIONS.md"
/bin/cp "$build_dir/checkouts/Ink/LICENSE" "$bundle_path/Contents/Resources/Ink-LICENSE.txt"
/usr/bin/ditto "$project_dir/Vendor/Tmux" "$bundle_path/Contents/Resources/tmux"
/bin/mkdir -p "$bundle_path/Contents/Resources/shell"
/bin/cp "$project_dir/Scripts/focus_queue_codex_entry.py" "$project_dir/Scripts/focus_queue_usage_wrapper.sh" \
  "$project_dir/Scripts/focus_queue_codex_bar.js" "$project_dir/Scripts/AgentUsageBar-LICENSE.txt" \
  "$project_dir/Scripts/install_codex_entry.py" \
  "$project_dir/Scripts/focus_queue_claude_entry.py" "$project_dir/Scripts/install_claude_entry.py" \
  "$bundle_path/Contents/Resources/shell/"
automation_resources="$bundle_path/Contents/Resources/automation"
/bin/mkdir -p "$automation_resources/Scripts" "$automation_resources/Config"
for script in \
  focus_queue_morning.py focus_queue_codex.py focus_queue_lock.py focus_queue_mail.py focus_queue_gmail.py \
  focus_queue_discord.py focus_queue_connectors.py focus-queue-mail.js; do
  /bin/cp "$project_dir/Scripts/$script" "$automation_resources/Scripts/$script"
done
/bin/cp "$project_dir/Config/task-proposals.schema.json" \
  "$automation_resources/Config/task-proposals.schema.json"

info_plist="$bundle_path/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$info_plist"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "$product_name" "$info_plist"
/usr/bin/plutil -insert CFBundleExecutable -string ECCFocusQueue "$info_plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.haelyra.ecc-focus-queue "$info_plist"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
/usr/bin/plutil -insert CFBundleName -string "$product_name" "$info_plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$info_plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.3.0 "$info_plist"
/usr/bin/plutil -insert CFBundleVersion -string 3 "$info_plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$info_plist"
/usr/bin/plutil -insert LSUIElement -bool true "$info_plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$info_plist"
/usr/bin/plutil -insert NSDocumentsFolderUsageDescription -string \
  "Focus Queue reads your local task dashboard from the Documents folder." "$info_plist"

integration_ref="${ECC_FOCUS_QUEUE_INTEGRATION_REF:-origin/main}"
/usr/bin/python3 "$project_dir/Scripts/focus_queue_install.py" \
  --write-provenance "$bundle_path/Contents/Resources/source-provenance.json" \
  --repository "$project_dir" \
  --integration-ref "$integration_ref" >/dev/null

sign_identity="${ECC_FOCUS_QUEUE_SIGN_IDENTITY:--}"
sign_options=()
app_requirements=()
if [[ "$sign_identity" == "-" ]]; then
  app_requirements=(--requirements '=designated => identifier "com.haelyra.ecc-focus-queue"')
else
  sign_options=(--options runtime --timestamp)
fi
/usr/bin/codesign --force --sign "$sign_identity" "${sign_options[@]}" \
  --identifier "com.haelyra.ecc-focus-queue.session" \
  "$bundle_path/Contents/MacOS/focus-queue-session"
/usr/bin/codesign --force --sign "$sign_identity" "${sign_options[@]}" \
  --identifier "com.haelyra.ecc-focus-queue.map" \
  "$bundle_path/Contents/MacOS/focus-queue-map"
/usr/bin/codesign --force --sign "$sign_identity" "${sign_options[@]}" "${app_requirements[@]}" "$bundle_path"
/usr/bin/codesign --verify --deep --strict "$bundle_path"

if [[ -e "$release_bundle" || -L "$release_bundle" ]]; then
  /bin/mkdir -p "$project_dir/dist/backups"
  /bin/mv "$release_bundle" "$project_dir/dist/backups/$product_name-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
fi
/bin/mv "$bundle_path" "$release_bundle"
/bin/rmdir "$staging_dir"
print -r -- "$release_bundle"
