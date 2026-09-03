#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
product_name="ECC Focus Queue"
bundle_path="$project_dir/dist/$product_name.app"
executable_path="$project_dir/.build/release/ECCFocusQueue"
session_helper_path="$project_dir/.build/release/focus-queue-session"

swift build --package-path "$project_dir" -c release

if [[ -e "$bundle_path" ]]; then
  /bin/rm -rf "$bundle_path"
fi
/bin/mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
/bin/cp "$executable_path" "$bundle_path/Contents/MacOS/ECCFocusQueue"
/bin/cp "$session_helper_path" "$bundle_path/Contents/MacOS/focus-queue-session"
/bin/cp "$project_dir/Config/config.example.json" "$bundle_path/Contents/Resources/config.example.json"
/bin/cp "$project_dir/Config/ecc.config.json" "$bundle_path/Contents/Resources/ecc.config.json"

info_plist="$bundle_path/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$info_plist"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "$product_name" "$info_plist"
/usr/bin/plutil -insert CFBundleExecutable -string ECCFocusQueue "$info_plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.haelyra.ecc-focus-queue "$info_plist"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
/usr/bin/plutil -insert CFBundleName -string "$product_name" "$info_plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$info_plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.2.0 "$info_plist"
/usr/bin/plutil -insert CFBundleVersion -string 2 "$info_plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$info_plist"
/usr/bin/plutil -insert LSUIElement -bool true "$info_plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$info_plist"
/usr/bin/plutil -insert NSDocumentsFolderUsageDescription -string \
  "ECC Focus Queue reads your local task dashboard from the Documents folder." "$info_plist"

designated_requirement='=designated => identifier "com.haelyra.ecc-focus-queue"'
/usr/bin/codesign --force --sign - \
  --identifier "com.haelyra.ecc-focus-queue.session" \
  "$bundle_path/Contents/MacOS/focus-queue-session"
/usr/bin/codesign --force --sign - --requirements "$designated_requirement" "$bundle_path"
/usr/bin/codesign --verify --deep --strict "$bundle_path"

print -r -- "$bundle_path"
