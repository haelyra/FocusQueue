#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
project_dir=${script_dir:h}
if [[ "${1:-}" != "--no-build" ]]; then
  "$script_dir/build-app.sh"
fi
bundle="$project_dir/dist/Focus Queue.app"
/usr/bin/codesign --verify --deep --strict "$bundle"
package_stage=$(/usr/bin/mktemp -d "$project_dir/dist/.package-stage.XXXXXX")
package_root="$package_stage/Focus Queue Beta"
/bin/mkdir -p "$package_root/Resources"
/usr/bin/ditto "$bundle" "$package_root/Focus Queue.app"
/bin/cp "$script_dir/Install.command" "$script_dir/Uninstall.command" "$package_root/"
/bin/cp "$script_dir/focus_queue_install.py" "$package_root/Resources/"
/bin/cp "$project_dir/Docs/BETA_README.txt" "$package_root/README.txt"
/bin/chmod 755 "$package_root/Install.command" "$package_root/Uninstall.command"
archive="$project_dir/dist/FocusQueue-0.3.2-beta-$(/usr/bin/uname -m).zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_root" "$archive"
(
  cd "$project_dir/dist"
  /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)
print -r -- "$archive"
print -r -- "Package staging retained for inspection: $package_root"
