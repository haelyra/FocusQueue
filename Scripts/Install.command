#!/bin/zsh
set -euo pipefail
package_dir=${0:A:h}
exec /usr/bin/python3 "$package_dir/Resources/focus_queue_install.py" \
  --bundle "$package_dir/ECC Focus Queue.app" "$@"
