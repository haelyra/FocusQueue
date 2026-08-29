#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
product_name="ECC Focus Queue"
bundle_path="$project_dir/dist/$product_name.app"
executable_path="$project_dir/.build/release/ECCFocusQueue"

swift build --package-path "$project_dir" -c release

if [[ -e "$bundle_path" ]]; then
  /bin/rm -rf "$bundle_path"
fi
/bin/mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
/bin/cp "$executable_path" "$bundle_path/Contents/MacOS/ECCFocusQueue"
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
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.1.0 "$info_plist"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$info_plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$info_plist"
/usr/bin/plutil -insert LSUIElement -bool true "$info_plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$info_plist"

/usr/bin/codesign --force --deep --sign - "$bundle_path"
/usr/bin/codesign --verify --deep --strict "$bundle_path"

print -r -- "$bundle_path"
