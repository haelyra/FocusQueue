#!/bin/bash
# Scoped adapter for the pinned upstream plugins. Never sources ~/.tmux.conf.
set -euo pipefail
umask 077

action=${1:?action required}
export FQ_TMUX_EXECUTABLE=${2:?tmux executable required}
export FQ_TMUX_SERVER=${3:?server name required}
state=${4:?state directory required}
resources=${5:?resource directory required}
interval=${6:-5}
heartbeat=${7:-30}
script="$resources/focus-queue-persistence.sh"
snapshots="$state/resurrect"
export TMUX_TMPDIR=/tmp
export LC_ALL=en_US.UTF-8
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$FQ_TMUX_EXECUTABLE")"
[[ "$FQ_TMUX_SERVER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$ ]] || exit 64
[[ "$FQ_TMUX_EXECUTABLE" == /* && "$state" == /* && "$resources" == /* ]] || exit 64
[[ "$interval" =~ ^[0-9]+$ && "$heartbeat" =~ ^[0-9]+$ ]] || exit 64

command_for() {
  printf '%q ' /bin/bash "$script" "$1" "$FQ_TMUX_EXECUTABLE" "$FQ_TMUX_SERVER" "$state" "$resources" "$interval" "$heartbeat"
  if [[ $# -gt 1 ]]; then printf '%q' "$2"; fi
}

if [[ "$action" == sanitize ]]; then
  snapshot=${8:?snapshot required}
  [[ "$snapshot" == "$snapshots"/tmux_resurrect_*.txt ]] || exit 64
  # Save layout and folders, without storing the agents' launch prompts/argv.
  /usr/bin/awk 'BEGIN { FS="\t"; OFS="\t" } $1 == "pane" { $10="shell"; $11=":" } { print }' "$snapshot" > "$snapshot.clean"
  "$FQ_TMUX_EXECUTABLE" -u -L "$FQ_TMUX_SERVER" list-panes -a \
    -F $'focus_queue\t#{session_name}\t#{window_index}\t#{pane_index}\t#{@focus-queue-task}\t#{@focus-queue-agent}\t#{@focus-queue-restored-agent}' \
    | /usr/bin/awk 'BEGIN { FS="\t"; OFS="\t" }
      $1 == "focus_queue" && $2 ~ /^fq-task-[A-Za-z0-9_-]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ &&
      $5 ~ /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/ && ($6 == "" || $6 ~ /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/) &&
      ($7 == "" || $7 ~ /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/) {
        if ($6 == "") $6=$7; NF=6; print
      }' \
    >> "$snapshot.clean"
  /bin/mv "$snapshot.clean" "$snapshot"
  exit 0
fi

placeholder=""
if ! "$FQ_TMUX_EXECUTABLE" -u -L "$FQ_TMUX_SERVER" display-message -p '#{pid}' >/dev/null 2>&1; then
  if [[ "$action" != restore ]]; then
    printf '%s\n' 'The managed tmux server is stopped.' >&2
    exit 1
  fi
  [[ -s "$snapshots/recovery/last" || -s "$snapshots/last" ]] || { printf '%s\n' 'There is no saved layout to restore.' >&2; exit 1; }
  placeholder=$("$FQ_TMUX_EXECUTABLE" -u -f /dev/null -L "$FQ_TMUX_SERVER" new-session -d -P -F '#{pane_id}' -s "fq-restore-$$" -c "${state//#/##}" /bin/sh)
fi

export FQ_TMUX_SOCKET
FQ_TMUX_SOCKET=$("$FQ_TMUX_EXECUTABLE" -u -L "$FQ_TMUX_SERVER" display-message -p '#{socket_path}')
server_pid=$("$FQ_TMUX_EXECUTABLE" -u -L "$FQ_TMUX_SERVER" display-message -p '#{pid}')
export TMUX="$FQ_TMUX_SOCKET,$server_pid,0"

tmux() {
  # Resurrect supplies -S for grouped sessions. Keep every invocation on our socket.
  while [[ ${1:-} == -S || ${1:-} == -L ]]; do shift 2; done
  "$FQ_TMUX_EXECUTABLE" -u -S "$FQ_TMUX_SOCKET" "$@"
}
export -f tmux

mkdir -p "$snapshots"
chmod 700 "$state" "$snapshots"

lock="$state/operation.lock"
locked=0
restore_options=0
default_command=""
unlock() {
  if [[ "$restore_options" == 1 ]]; then
    tmux set-option -g default-command "$default_command" 2>/dev/null || true
    tmux set-option -g @resurrect-dir "$snapshots" 2>/dev/null || true
  fi
  if [[ "$locked" == 1 ]]; then
    /bin/rm -f "$lock/pid"
    /bin/rmdir "$lock" 2>/dev/null || true
  fi
}
trap unlock EXIT
acquire_lock() {
  local attempt=0 owner=""
  until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      /bin/rm -f "$lock/pid"
      /bin/rmdir "$lock" 2>/dev/null || true
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -gt 100 ]]; then printf '%s\n' 'A tmux save or restore is already in progress. Retry shortly.' >&2; exit 1; fi
    sleep 0.1
  done
  locked=1
  printf '%s\n' "$$" > "$lock/pid"
}

configure() {
  if [[ -z "$(tmux show-option -gqv @focus-queue-persistence-initialized)" ]]; then
    # Preserve recovery across autosaves made by a newly started server.
    # An unresolved recovery copy survives another empty bootstrap/restart.
    if [[ -s "$snapshots/last" && ! -s "$snapshots/recovery/last" ]]; then
      mkdir -p "$snapshots/recovery"
      /bin/cp -p "$snapshots/last" "$snapshots/recovery/last"
    fi
    tmux set-option -g @focus-queue-persistence-initialized 1
    tmux set-option -g @continuum-save-last-timestamp "$(date +%s)"
  fi
  tmux set-option -g @resurrect-dir "$snapshots"
  tmux set-option -g @resurrect-processes false
  tmux set-option -g @resurrect-never-overwrite on
  tmux set-option -g @resurrect-capture-pane-contents off
  tmux set-option -g @resurrect-save-script-path "$state/save.sh"
  tmux set-option -g @resurrect-hook-post-save-layout "$(command_for sanitize)"
  tmux set-option -g @continuum-save-interval "$interval"
  tmux set-option -g @continuum-restore off
  tmux set-option -g @continuum-boot off
  tmux bind-key C-s run-shell -b "$(command_for save)"
  tmux bind-key C-r run-shell -b "$(command_for restore)"
  tmux set-hook -g 'client-detached[935]' "run-shell -b $(printf '%q' "$(command_for save)")"
}

schedule_tick() {
  local generation="$1"
  tmux run-shell -b -d "$heartbeat" "$(command_for tick "$generation")"
}

save_current() {
  # Resurrect uses second-resolution filenames. Avoid overwriting its own last file.
  if [[ "$(readlink "$snapshots/last" 2>/dev/null || true)" == "tmux_resurrect_$(date +%Y%m%dT%H%M%S).txt" ]]; then sleep 1; fi
  /bin/bash "$resources/tmux-resurrect/scripts/save.sh" quiet
  [[ -s "$snapshots/last" ]] || { printf '%s\n' 'tmux did not produce a saved layout.' >&2; exit 1; }
}

case "$action" in
  setup)
    acquire_lock
    configure
    generation="$server_pid-$$-$RANDOM"
    tmux set-option -g @focus-queue-persistence-loop "$generation"
    schedule_tick "$generation"
    ;;
  tick)
    generation=${8:?generation required}
    [[ "$(tmux show-option -gqv @focus-queue-persistence-loop)" == "$generation" ]] || exit 0
    schedule_tick "$generation"
    # Continuum retains ownership of its interval and concurrent-save guard.
    # A tmux timer runs this even when no status line/client is attached.
    /bin/bash "$resources/tmux-continuum/scripts/continuum_save.sh"
    ;;
  save)
    acquire_lock
    save_current
    ;;
  restore)
    acquire_lock
    configure
    restore_directory="$snapshots"
    if [[ -s "$snapshots/recovery/last" ]]; then restore_directory="$snapshots/recovery"; fi
    [[ -s "$restore_directory/last" ]] || { printf '%s\n' 'There is no saved layout to restore.' >&2; exit 1; }
    before=$(tmux list-panes -a -F '#{pane_id}')
    before_sessions=$(tmux list-sessions -F '#{session_name}')
    expected_targets=$(/usr/bin/awk 'BEGIN { FS="\t" } $1 == "pane" { print $2 ":" $3 "." $6 }' "$restore_directory/last")
    expected_sessions=$(/usr/bin/awk 'BEGIN { FS="\t" } $1 == "pane" { print $2 }' "$restore_directory/last" | /usr/bin/sort -u)
    [[ -n "$expected_targets" ]] || { printf '%s\n' 'The saved layout contains no panes.' >&2; exit 1; }
    tmux set-option -g @resurrect-dir "$restore_directory"
    # Never let a custom default-command replay an old provider invocation.
    default_command=$(tmux show-option -gqv default-command)
    restore_options=1
    tmux set-option -g default-command ''
    /bin/bash "$resources/tmux-resurrect/scripts/restore.sh"
    tmux set-option -g default-command "$default_command"
    tmux set-option -g @resurrect-dir "$snapshots"
    restore_options=0
    while IFS= read -r target; do
      tmux display-message -p -t "=$target" '#{pane_id}' >/dev/null || {
        printf '%s\n' 'Some saved panes could not be restored. The recovery snapshot has been retained.' >&2
        exit 1
      }
    done <<< "$expected_targets"
    # Apply ownership only after resurrect has finished replacing its bootstrap
    # pane. Earlier assignment can land on the pane that restore then removes.
    while IFS=$'\t' read -r kind session window pane task agent extra; do
      [[ "$kind" == focus_queue ]] || continue
      [[ "$session" =~ ^fq-task-[A-Za-z0-9_-]+$ && "$window" =~ ^[0-9]+$ && "$pane" =~ ^[0-9]+$ ]] || continue
      [[ "$task" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$ ]] || continue
      [[ -z "$agent" || "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$ ]] || continue
      # Never adopt a reserved-name session that belonged to another caller
      # before this restore. This also protects preexisting panes if resurrect
      # adds a saved window to a colliding session name.
      printf '%s\n' "$before_sessions" | /usr/bin/grep -Fqx -- "$session" && continue
      target="=$session:$window.$pane"
      pane_id=$(tmux display-message -p -t "$target" '#{pane_id}') || continue
      tmux set-option -t "=$session:" @focus-queue-task "$task"
      if ! printf '%s\n' "$before" | /usr/bin/grep -Fqx -- "$pane_id"; then
        tmux set-option -p -u -t "$target" @focus-queue-agent 2>/dev/null || true
        if [[ -n "$agent" ]]; then
          tmux set-option -p -t "$target" @focus-queue-restored-agent "$agent"
        fi
      fi
    done < "$restore_directory/last"
    # Older snapshots have no Focus Queue metadata. Only a reserved session
    # named in the snapshot and newly created by this restore may infer task
    # ownership. Panes remain unassigned shells.
    while IFS=$'\t' read -r session owner; do
      [[ "$session" =~ ^fq-task-[A-Za-z0-9_-]+$ && -z "$owner" ]] || continue
      printf '%s\n' "$expected_sessions" | /usr/bin/grep -Fqx -- "$session" || continue
      printf '%s\n' "$before_sessions" | /usr/bin/grep -Fqx -- "$session" && continue
      task=$(printf '%s' "${session#fq-task-}" | /usr/bin/tr '[:lower:]' '[:upper:]')
      tmux set-option -t "=$session:" @focus-queue-task "$task"
    done < <(tmux list-sessions -F $'#{session_name}\t#{@focus-queue-task}')
    while IFS= read -r pane; do
      if ! printf '%s\n' "$before" | /usr/bin/grep -Fqx -- "$pane"; then
        tmux set-option -p -t "$pane" @focus-queue-restored 1
      fi
    done < <(tmux list-panes -a -F '#{pane_id}')
    if [[ -n "$placeholder" && "$(tmux list-panes -a -F '#{pane_id}' | wc -l)" -gt 1 ]]; then
      tmux kill-pane -t "$placeholder"
    fi
    save_current
    if [[ "$restore_directory" == "$snapshots/recovery" ]]; then
      /bin/mv "$snapshots/recovery/last" "$snapshots/recovery/restored-$(date +%Y%m%dT%H%M%S).txt"
    fi
    generation="$server_pid-$$-$RANDOM"
    tmux set-option -g @focus-queue-persistence-loop "$generation"
    schedule_tick "$generation"
    ;;
  *) printf '%s\n' 'Unknown persistence action.' >&2; exit 64 ;;
esac
