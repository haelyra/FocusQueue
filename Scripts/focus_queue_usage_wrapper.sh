#!/bin/bash
# Keep direct-terminal behavior in the user's configured wrapper. Inside the
# private Focus Queue tmux server, give each agent pane its own usage bar in
# its top pane border; tmux has no per-pane status rows, and the border is
# the only surface whose format resolves pane-scoped values per pane.

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

run_managed_codex() {
  codex "$@"
  local provider_status=$?
  if [ "$provider_status" -eq 0 ] \
    && [ -n "${FOCUS_QUEUE_TASK_ID:-}" ] \
    && [ -n "${FOCUS_QUEUE_SUBTASK_ID:-}" ] \
    && command -v focus-queue-session >/dev/null 2>&1; then
    focus-queue-session archive-agent \
      "$FOCUS_QUEUE_TASK_ID" "$FOCUS_QUEUE_SUBTASK_ID" >/dev/null 2>&1 || true
  fi
  exit "$provider_status"
}

if ! managed_tmux; then
  exec /bin/bash "$delegate" "$@"
fi

bar="$(cd "$(dirname "$0")" && pwd -P)/focus_queue_codex_bar.js"
node_path="$(command -v node 2>/dev/null || true)"
context="${FOCUS_QUEUE_TASK_CONTEXT:-}"
if [ -z "$context" ] && [ -n "${FOCUS_QUEUE_SUPPORT_DIR:-}" ] && [ -n "${FOCUS_QUEUE_TASK_ID:-}" ]; then
  task_id="$(printf '%s' "$FOCUS_QUEUE_TASK_ID" | tr '[:lower:]' '[:upper:]')"
  context="${FOCUS_QUEUE_SUPPORT_DIR%/}/tasks/${task_id}/context.json"
fi
if [ -z "$node_path" ] || [ ! -f "$bar" ] || [[ "$context" != /* ]] || [ ! -f "$context" ]; then
  printf '%s\n' 'Focus Queue: the configured usage renderer is unavailable; starting Codex without a bar.' >&2
  run_managed_codex "$@"
fi

interval=${USAGE_BAR_INTERVAL:-15}
case "$interval" in
  ''|*[!0-9]*|?????*) interval=15 ;;
  *)
    interval=$((10#$interval))
    if [ "$interval" -lt 1 ] || [ "$interval" -gt 3600 ]; then interval=15; fi
    ;;
esac

usage_enabled=on
if [ "${FOCUS_QUEUE_USAGE_BAR:-${USAGE_BAR:-on}}" = "off" ]; then usage_enabled=off; fi

native_row="$(tmux show-options -gv 'status-format[0]' 2>/dev/null || true)"
if [ -z "$native_row" ]; then
  native_row='#[align=left]#{W:#[fg=colour245] #I:#W ,#[bold] #I:#W }'
fi
# The session keeps one native window-tab row; usage moved to pane borders.
tmux set-option -t "$TMUX_PANE" status on >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-position bottom >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-interval "$interval" >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" status-style 'bg=default,fg=default' >/dev/null 2>&1 || true
tmux set-option -t "$TMUX_PANE" 'status-format[0]' "$native_row" >/dev/null 2>&1 || true
for line in 1 2 3; do
  tmux set-option -u -t "$TMUX_PANE" "status-format[$line]" >/dev/null 2>&1 || true
done

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

printf -v node_q '%q' "$node_path"
printf -v bar_q '%q' "$bar"
printf -v context_q '%q' "$context"
node_q=${node_q//#/##}
bar_q=${bar_q//#/##}
context_q=${context_q//#/##}

# The pane's durable agent marker selects its exact provider session. Literal
# executable and renderer paths avoid tmux background-job environment
# differences, which otherwise produce a silently blank border.
usage_command="USAGE_BAR_GLYPHS=$glyphs $node_q $bar_q --tmux --context $context_q --agent \"#{@focus-queue-agent}\" --cwd #{q:pane_current_path} --line 0"
if [ "$usage_enabled" = off ]; then usage_command=""; fi
tmux set-option -t "$TMUX_PANE" @focus-queue-usage-command "$usage_command" >/dev/null 2>&1 || true
# The border leads with this pane's agent label, falling back to the task
# title when no label is registered yet. A literal label escapes "#" so tmux
# keeps it verbatim.
pane_label="$(tmux show-options -qv -p -t "$TMUX_PANE" @focus-queue-label 2>/dev/null || true)"
pane_label="$(printf '%s' "$pane_label" | tr -d '[:cntrl:]')"
if [ -n "$pane_label" ]; then
  border_format="#[align=left] #[bold]${pane_label//#/##}#[default]"
else
  border_format='#[align=left] #[bold]#{@focus-queue-task-title}#[default]'
fi
if [ -n "$usage_command" ]; then border_format="$border_format  #($usage_command)"; fi
tmux set-window-option -t "$TMUX_PANE" pane-border-status top >/dev/null 2>&1 || true
tmux set-window-option -t "$TMUX_PANE" pane-border-format "$border_format" >/dev/null 2>&1 || true

run_managed_codex "$@"
