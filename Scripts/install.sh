#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build=1
installer_arguments=()
for argument in "$@"; do
  case "$argument" in
    --no-build) build=0 ;;
    --check) build=0; installer_arguments+=(--check) ;;
    --login|--desktop|--no-start) installer_arguments+=("$argument") ;;
    --help|-h)
      print -r -- "Usage: $0 [--no-build|--check] [--login] [--desktop] [--no-start]"
      print -r -- "Installs the app and session helper for the current user. Existing configuration is preserved."
      exit 0 ;;
    *) print -u2 -r -- "Unknown option: $argument"; exit 2 ;;
  esac
done
if (( build )); then
  "$script_dir/build-app.sh"
fi
exec /usr/bin/python3 "$script_dir/focus_queue_install.py" \
  --bundle "$project_dir/dist/Focus Queue.app" "${installer_arguments[@]}"
