#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
project_dir=${script_dir:h}
sign_tool="$script_dir/sign-release.swift"
trusted_keys="$project_dir/Sources/FocusQueueCore/ReleaseSigning.swift"
# The in-app updater installs only releases signed by a key in
# ReleaseSigning.trustedPublicKeys, so check the key before building.
signing_key=""
if signing_key=$(/usr/bin/swift "$sign_tool" public-key); then
  if ! /usr/bin/grep -qF "\"$signing_key\"" "$trusted_keys"; then
    print -u2 -r -- "package-release: signing key $signing_key is not listed in $trusted_keys; installed apps would refuse this release."
    exit 1
  fi
elif [[ "${FOCUS_QUEUE_ALLOW_UNSIGNED_RELEASE:-}" == 1 ]]; then
  signing_key=""
  print -u2 -r -- "package-release: WARNING: packaging an UNSIGNED release because FOCUS_QUEUE_ALLOW_UNSIGNED_RELEASE=1. The in-app updater will refuse to install it."
else
  print -u2 -r -- "package-release: no release signing key. Create one with 'swift Scripts/sign-release.swift keygen' (Docs/LAUNCH_BETA.md), or set FOCUS_QUEUE_ALLOW_UNSIGNED_RELEASE=1 for a local package the updater will refuse."
  exit 1
fi
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
archive="$project_dir/dist/FocusQueue-0.3.5-beta-$(/usr/bin/uname -m).zip"
/bin/rm -f "$archive.sig"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_root" "$archive"
(
  cd "$project_dir/dist"
  /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)
if [[ -n "$signing_key" ]]; then
  /usr/bin/swift "$sign_tool" sign "$archive" >/dev/null
  /usr/bin/swift "$sign_tool" verify "$archive" "$signing_key" >/dev/null
  print -r -- "$archive.sig"
fi
print -r -- "$archive"
print -r -- "Package staging retained for inspection: $package_root"
