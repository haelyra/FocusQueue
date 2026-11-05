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
if [[ -t 0 ]]; then
  exec /usr/bin/python3 "$package_dir/Resources/focus_queue_install.py" \
    --bundle "$package_dir/Focus Queue.app" "$@"
fi
# No terminal means the app's Install update button started this, and that app
# waits for a restart it cannot see fail. Put any failure on screen instead.
errors=$(/usr/bin/mktemp -t focus-queue-update)
exit_code=0
/usr/bin/python3 "$package_dir/Resources/focus_queue_install.py" \
  --bundle "$package_dir/Focus Queue.app" --unattended "$@" 2>"$errors" || exit_code=$?
/bin/cat "$errors" >&2
if (( exit_code )); then
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display alert "Focus Queue could not install the update" message (item 1 of argv) as critical' \
    -e 'end run' \
    "$(/usr/bin/tail -n 3 "$errors")

Quit Focus Queue and open it again, then retry from Settings > Updates." >/dev/null 2>&1 || true
fi
/bin/rm -f "$errors"
exit "$exit_code"
