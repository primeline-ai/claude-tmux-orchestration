#!/usr/bin/env bash
# rate-limit-watchdog.sh -Auto-recovery for API rate limits in tmux sessions
#
# Problem: When Claude Code hits an API rate limit during a command (e.g. /commit),
# the agent stops and waits for user input. If you paste the error back, Claude
# interprets it as "the command is broken" and uses a workaround instead of retrying.
#
# Solution: This watchdog monitors tmux pane output for rate limit patterns,
# waits for the cooldown to pass, then sends an explicit retry message that
# tells Claude "this was a TEMPORARY rate limit, not a bug -retry the exact
# same command, don't use a workaround."
#
# Usage:
#   ./_orchestrator/rate-limit-watchdog.sh                  # Monitor all claude sessions
#   ./_orchestrator/rate-limit-watchdog.sh <session-name>   # Monitor specific session
#   ./_orchestrator/rate-limit-watchdog.sh --status          # Check if running
#   ./_orchestrator/rate-limit-watchdog.sh --stop            # Kill watchdog
#
# Auto-started by orch-bootstrap.sh. Auto-stopped on .stop signal.

set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH_DIR="${ORCH_DIR:-$SCRIPT_DIR}"

# --- Config (reads from config.json if available) ---
_read_config() {
  local key="$1" default="$2"
  local config_file="${ORCH_DIR}/config.json"
  if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
    local val
    val=$(jq -r "$key // empty" "$config_file" 2>/dev/null)
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

CHECK_INTERVAL=$(_read_config '.watchdog.check_interval' '15')
COOLDOWN=$(_read_config '.watchdog.cooldown_seconds' '65')
MAX_RETRIES=$(_read_config '.watchdog.max_retries' '5')
BACKOFF_MULTIPLIER=$(_read_config '.watchdog.backoff_multiplier' '2')
LOG_FILE="${ORCH_DIR}/watchdog.log"
PID_FILE="${ORCH_DIR}/watchdog.pid"

# Rate limit detection patterns
RATE_LIMIT_PATTERNS=(
    "Rate limit"
    "rate_limit"
    "rate limit reached"
    "Too many requests"
    "\\b429\\b"
    "API Error.*[Rr]ate"
    "overloaded"
)

# --- State (file-based, bash 3 compatible -macOS ships bash 3) ---
STATE_DIR="/tmp/rate-limit-watchdog-state-$$"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT

get_state() { cat "$STATE_DIR/$1_$2" 2>/dev/null || echo "$3"; }
set_state() { echo "$3" > "$STATE_DIR/$1_$2"; }

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

# --- Command Detection ---
detect_failed_command() {
    # Extract the slash command that was running when rate limit hit
    # Only matches Claude Code slash commands (e.g. "Using /whats-next to...")
    # Excludes file paths (/Users/..., /tmp/...) and URLs
    local output="$1"
    local cmd=""

    # Pattern: "Using /command" or "Invoking /command" (skill invocation lines)
    cmd=$(echo "$output" | grep -oE '(Using|Invoking|Running) /[-a-zA-Z0-9_:]+' | tail -1 | grep -oE '/[-a-zA-Z0-9_:]+')

    # Fallback: slash command at line start (user typed it directly)
    if [[ -z "$cmd" ]]; then
        cmd=$(echo "$output" | grep -oE '^/[-a-zA-Z0-9_:]+' | tail -1)
    fi

    echo "$cmd"
}

build_resume_message() {
    local output="$1"
    local failed_cmd
    failed_cmd=$(detect_failed_command "$output")

    if [[ -n "$failed_cmd" ]]; then
        # Command-specific: tell Claude exactly what to retry
        echo "The command ${failed_cmd} failed due to a TEMPORARY API rate limit. This is NOT a bug in the command itself. The rate limit has passed. Please run ${failed_cmd} again -the exact same command, NO workaround, NO alternative approach."
    else
        # Generic: no command detected, guide Claude to check its plan
        echo "The last step failed due to a TEMPORARY API rate limit and was NOT executed. The rate limit has passed. Check your TodoList or plan, find the last OPEN task, and execute that exact step again -NO workaround, NO alternative approach."
    fi
}

# --- Detection ---
check_rate_limit_in_output() {
    local output="$1"
    for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1
}

get_claude_tmux_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r session; do
        local pane_cmd
        pane_cmd=$(tmux list-panes -t "$session" -F '#{pane_current_command}' 2>/dev/null | head -1)
        if [[ "$pane_cmd" == *"claude"* ]] || [[ "$pane_cmd" == *"node"* ]]; then
            echo "$session"
        fi
    done
}

# --- Core Loop ---
monitor_session() {
    local session="$1"
    local session_key="${session//[^a-zA-Z0-9_]/_}"

    # Capture last 30 lines of tmux pane
    local output
    output=$(tmux capture-pane -t "$session" -p -S -30 2>/dev/null) || return

    if check_rate_limit_in_output "$output"; then
        local now
        now=$(date +%s)
        local last=$(get_state "$session_key" "last" "0")
        local retries=$(get_state "$session_key" "retries" "0")

        # Prevent rapid-fire retries (min 30s between triggers)
        if (( now - last < 30 )); then
            return
        fi

        # Exponential backoff after max retries
        if (( retries >= MAX_RETRIES )); then
            local backoff_wait=$(( COOLDOWN * BACKOFF_MULTIPLIER * (retries - MAX_RETRIES + 1) ))
            if (( backoff_wait > 600 )); then
                backoff_wait=600  # Cap at 10 minutes
            fi
            log "BACKOFF [$session]: $retries consecutive retries, waiting ${backoff_wait}s"
            sleep "$backoff_wait"
            set_state "$session_key" "retries" "0"
        fi

        log "RATE LIMIT [$session]: Detected. Waiting ${COOLDOWN}s before resume..."
        sleep "$COOLDOWN"

        # Check again -maybe it resolved on its own
        local fresh_output
        fresh_output=$(tmux capture-pane -t "$session" -p -S -5 2>/dev/null) || return

        if check_rate_limit_in_output "$fresh_output" || ! echo "$fresh_output" | grep -q "❯\|>\|claude\|─"; then
            local resume_msg
            resume_msg=$(build_resume_message "$output")
            tmux send-keys -t "$session" -l "$resume_msg"
            sleep 0.5
            tmux send-keys -t "$session" Enter
            local detected_cmd
            detected_cmd=$(detect_failed_command "$output")
            log "RESUME [$session]: ${detected_cmd:-generic}"
            set_state "$session_key" "retries" "$(( retries + 1 ))"
        else
            log "RESOLVED [$session]: Rate limit cleared on its own"
            set_state "$session_key" "retries" "0"
        fi

        set_state "$session_key" "last" "$now"
    else
        # No rate limit -reset counter if we had retries
        local cur_retries=$(get_state "$session_key" "retries" "0")
        if (( cur_retries > 0 )); then
            log "CLEAR [$session]: Session recovered after ${cur_retries} retries"
            set_state "$session_key" "retries" "0"
        fi
    fi
}

monitor_all() {
    log "START: Watchdog monitoring all claude sessions (interval: ${CHECK_INTERVAL}s, cooldown: ${COOLDOWN}s)"
    echo $$ > "$PID_FILE"

    while true; do
        # Honor .stop signal from orchestrator
        if [[ -f "${ORCH_DIR}/.stop" ]]; then
            log "STOP: .stop signal detected. Shutting down watchdog."
            rm -f "$PID_FILE"
            exit 0
        fi

        local sessions
        sessions=$(get_claude_tmux_sessions)

        if [[ -n "$sessions" ]]; then
            while read -r session; do
                [[ -n "$session" ]] && monitor_session "$session"
            done <<< "$sessions"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

monitor_single() {
    local session="$1"
    log "START: Watchdog monitoring session '$session' (interval: ${CHECK_INTERVAL}s, cooldown: ${COOLDOWN}s)"
    echo $$ > "$PID_FILE"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "ERROR: tmux session '$session' not found"
        exit 1
    fi

    while true; do
        if [[ -f "${ORCH_DIR}/.stop" ]]; then
            log "STOP: .stop signal detected. Shutting down watchdog."
            rm -f "$PID_FILE"
            exit 0
        fi

        if ! tmux has-session -t "$session" 2>/dev/null; then
            log "END: Session '$session' no longer exists. Stopping watchdog."
            rm -f "$PID_FILE"
            exit 0
        fi

        monitor_session "$session"
        sleep "$CHECK_INTERVAL"
    done
}

# --- Entry Point ---
case "${1:-}" in
    --help|-h)
        head -17 "$0" | tail -15
        echo ""
        echo "Config (in config.json under 'watchdog' key):"
        echo "  check_interval:      $CHECK_INTERVAL seconds"
        echo "  cooldown_seconds:    $COOLDOWN seconds"
        echo "  max_retries:         $MAX_RETRIES before backoff"
        echo "  backoff_multiplier:  $BACKOFF_MULTIPLIER"
        echo ""
        echo "Log: $LOG_FILE"
        exit 0
        ;;
    --stop)
        if [[ -f "$PID_FILE" ]]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null && echo "Watchdog stopped" || echo "Watchdog not running (stale PID)"
            rm -f "$PID_FILE"
        else
            pkill -f "rate-limit-watchdog.sh" 2>/dev/null && echo "Watchdog stopped" || echo "No watchdog running"
        fi
        exit 0
        ;;
    --status)
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "Watchdog is running (PID: $(cat "$PID_FILE"))"
            echo "Log: $LOG_FILE"
            tail -5 "$LOG_FILE" 2>/dev/null || echo "(no log entries)"
        else
            echo "Watchdog is not running"
            rm -f "$PID_FILE" 2>/dev/null
        fi
        exit 0
        ;;
    "")
        monitor_all
        ;;
    *)
        monitor_single "$1"
        ;;
esac
