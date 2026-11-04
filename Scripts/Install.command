#!/bin/zsh
set -euo pipefail
package_dir=${0:A:h}
# /usr/bin/python3 and git come with Apple's Command Line Tools. Without them
# python3 is only a stub that opens Apple's installer, so check before using it.
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  if (( ${@[(Ie)--check]} )); then
    print -u2 -- "Apple's Command Line Tools (git, python3) are not installed. Run Install.command without --check to install them."
  else
    print -u2 -- "Focus Queue needs Apple's Command Line Tools (git, python3). Apple's installer is opening now; run Install.command again when it finishes."
    /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  fi
  exit 1
fi
exec /usr/bin/python3 "$package_dir/Resources/focus_queue_install.py" \
  --bundle "$package_dir/Focus Queue.app" "$@"
