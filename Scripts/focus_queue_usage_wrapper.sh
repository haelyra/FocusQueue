#!/bin/bash
# Keep direct-terminal behavior in the user's configured wrapper. Inside the
# private Focus Queue tmux server, install one active-pane-aware status bar for
# the task session so several agent panes cannot overwrite one another.

set -uo pipefail

delegate="${1:-}"
if [ "$#" -lt 2 ] || [ "$2" != "--" ] || [[ "$delegate" != /* ]] || [ ! -f "$delegate" ]; then
  printf '%s\n' 'Focus Queue usage wrapper: invalid configured wrapper.' >&2
  exit 64
fi
shift 2

managed_tmux() {
  [ "${FOCUS_QUEUE_MANAGED_TMUX:-}" = "1" ] \
    && [ -n "${TMUX:-}" ] \
    && [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] \
    && [[ "${FOCUS_QUEUE_TMUX_NAME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$ ]] \
    && command -v tmux >/dev/null 2>&1 \
    && [ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = "$FOCUS_QUEUE_TMUX_NAME" ]
}

if ! managed_tmux; then
  exec /bin/bash "$delegate" "$@"
fi

if [ "${USAGE_BAR:-on}" = "off" ]; then
  exec codex "$@"
fi

bar="$(dirname "$delegate")/codex-bar.js"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$bar" ]; then
  printf '%s\n' 'Focus Queue: the configured usage renderer is unavailable; starting Codex without a bar.' >&2
  exec codex "$@"
fi

interval=${USAGE_BAR_INTERVAL:-15}
case "$interval" in
  ''|*[!0-9]*|?????*) interval=15 ;;
  *)
    interval=$((10#$interval))
    if [ "$interval" -lt 1 ] || [ "$interval" -gt 3600 ]; then interval=15; fi
    ;;
esac

tmux set-option -t "$TMUX_PANE" status 4 >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-position bottom >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-interval "$interval" >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-style 'bg=default,fg=default' >/dev/null 2>&1 || true
tmux set-environment -t "$TMUX_PANE" FOCUS_QUEUE_USAGE_BAR_PATH "$bar" >/dev/null 2>&1 || true

case "${USAGE_BAR_GLYPHS:-}" in
  ascii|unicode) glyphs=$USAGE_BAR_GLYPHS ;;
  *)
    glyphs=ascii
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *[Uu][Tt][Ff]*) glyphs=unicode ;;
    esac
    [ "$(tmux display-message -p '#{client_utf8}' 2>/dev/null)" = "1" ] && glyphs=unicode
    ;;
esac

for line in 1 2 3; do
  # tmux expands #{pane_pid} for the active pane when it refreshes the status
  # line. No agent-specific PID is stored in the session, and exiting one pane
  # deliberately leaves the shared renderer available to the other panes.
  format="#[align=left,bg=default,fg=default]#(USAGE_BAR_WRAPPER_PID=#{pane_pid} USAGE_BAR_GLYPHS=$glyphs node \"\$FOCUS_QUEUE_USAGE_BAR_PATH\" --tmux --line $line)"
  tmux set-option -t "$TMUX_PANE" "status-format[$line]" "$format" >/dev/null 2>&1 || true
done

codex "$@"
