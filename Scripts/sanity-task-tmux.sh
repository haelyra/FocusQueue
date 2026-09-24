#!/bin/zsh
set -euo pipefail

# Real tmux workflow sanity for one task session with four login-shell agent
# panes. The session remains alive until the explicit cleanup action.

action="${1:-start}"
task_id="${2:-TEST}"
open_view="${3:-}"

if [[ ! "$task_id" =~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,69}$' ]]; then
  print -u2 -- "Task ID must contain only letters, numbers, hyphens, or underscores."
  exit 64
fi

script_dir="${0:A:h}"
repository="${script_dir:h}"
helper="$repository/.build/debug/focus-queue-session"
if [[ ! -x "$helper" ]]; then
  helper="${commands[focus-queue-session]:-}"
fi
tmux_executable="${commands[tmux]:-}"
if [[ -z "$helper" || ! -x "$helper" || -z "$tmux_executable" || ! -x "$tmux_executable" ]]; then
  print -u2 -- "Build focus-queue-session and install tmux before running this sanity check."
  exit 69
fi

server="ecc-focus-queue"
session="fq-task-${task_id:l}"
support_root="${TMPDIR:-/tmp}/focus-queue-tmux-sanity-${UID}"
mkdir -p -m 700 "$support_root"

tmux_command() {
  TMUX_TMPDIR=/tmp "$tmux_executable" -L "$server" "$@"
}

session_exists() {
  tmux_command has-session -t "=$session" 2>/dev/null
}

require_owned_session() {
  session_exists || { print -u2 -- "No sanity session named $session is running."; exit 66; }
  local owner
  owner="$(tmux_command show-options -qv -t "=$session:" @focus-queue-task)"
  if [[ "$owner" != "${task_id:u}" ]]; then
    print -u2 -- "Refusing to change $session because its owner is '$owner', not ${task_id:u}."
    exit 77
  fi
}

start_agent() {
  local index="$1"
  local agent_id="sanity-${index}"
  local pane_script='print -r -- "Focus Queue tmux sanity: ${FOCUS_QUEUE_SANITY_AGENT}"; whence -v codex || true; whence -v focus-queue-session || true; print -r -- "Login-shell aliases loaded. This pane intentionally remains open."; exec /bin/zsh -l'
  FOCUS_QUEUE_SUPPORT_DIR="$support_root" "$helper" tmux start-agent \
    "$task_id" "$agent_id" --cwd "$repository" -- \
    /usr/bin/env "FOCUS_QUEUE_SANITY_AGENT=$agent_id" /bin/zsh -lic "$pane_script"
}

pane_for_agent() {
  local agent_id="$1"
  tmux_command list-panes -s -t "=$session:" -F '#{@focus-queue-agent}|#{pane_id}' \
    | /usr/bin/awk -F '|' -v agent="$agent_id" '$1 == agent { print $2 }'
}

show_status() {
  require_owned_session
  tmux_command list-panes -s -t "=$session:" \
    -F 'tab=#{window_index} pane=#{pane_id} agent=#{@focus-queue-agent} completed=#{@focus-queue-completed-agent} command=#{pane_current_command}' \
    | /usr/bin/sort
  local active tabs
  active="$(tmux_command list-panes -s -t "=$session:" -F '#{@focus-queue-agent}' | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
  tabs="$(tmux_command list-windows -t "=$session:" -F '#{window_id}' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  print -- "session=$session active_agents=$active tmux_windows=$tabs"
}

open_session() {
  if [[ "${ECC_FOCUS_QUEUE_UI_TESTS:-}" != "1" ]]; then
    print -u2 -- "The tmux session is running. Set ECC_FOCUS_QUEUE_UI_TESTS=1 for this run to open its WezTerm view."
    return 0
  fi
  /usr/bin/open -na WezTerm --args --skip-config start --always-new-process -- \
    "$helper" tmux attach "$session"
  print -- "Opened $session in WezTerm; the tmux session remains alive when that view closes."
}

case "$action" in
  start)
    if session_exists; then
      print -u2 -- "$session already exists. Use status, remove, reopen, or cleanup."
      exit 65
    fi
    for index in 1 2 3 4; do start_agent "$index" >/dev/null; done
    show_status
    if [[ "$open_view" == "--open" ]]; then open_session; fi
    print -- "Attach later with: $helper tmux attach $session"
    ;;
  status)
    show_status
    ;;
  remove)
    require_owned_session
    index="${3:-4}"
    pane="$(pane_for_agent "sanity-${index}")"
    [[ -n "$pane" ]] || { print -u2 -- "sanity-${index} is not active."; exit 66; }
    tmux_command kill-pane -t "$pane"
    FOCUS_QUEUE_SUPPORT_DIR="$support_root" "$helper" tmux reflow "$session"
    show_status
    ;;
  reopen)
    require_owned_session
    index="${3:-4}"
    [[ -z "$(pane_for_agent "sanity-${index}")" ]] \
      || { print -u2 -- "sanity-${index} is already active."; exit 65; }
    start_agent "$index" >/dev/null
    show_status
    ;;
  open)
    require_owned_session
    open_session
    ;;
  cleanup)
    require_owned_session
    tmux_command kill-session -t "=$session"
    print -- "Stopped sanity session $session."
    ;;
  *)
    print -u2 -- "Usage: $0 {start|status|remove|reopen|open|cleanup} [TASK-ID] [--open|AGENT-NUMBER]"
    exit 64
    ;;
esac
