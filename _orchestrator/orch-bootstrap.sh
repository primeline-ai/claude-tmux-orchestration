#!/usr/bin/env bash
# orch-bootstrap.sh — Entry point for Claude Code tmux Orchestrator
#
# Checks dependencies, ensures tmux session, exports ENV, starts heartbeat.
# Session name is derived from project directory: orch-<project-name>
#
# Usage: ./_orchestrator/orch-bootstrap.sh
#    or: PROJECT_ROOT=/path/to/project ./_orchestrator/orch-bootstrap.sh
#
# Full guide: https://primeline.cc/blog/tmux-orchestration

set -euo pipefail

# --- Project Root ---
if [[ -z "${PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
export PROJECT_ROOT

ORCH_DIR="${PROJECT_ROOT}/_orchestrator"
SESSION_NAME="orch-$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[orch]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[orch]${NC} $*"; }
log_error() { echo -e "${RED}[orch]${NC} $*"; }

# --- Dependency Check ---
check_deps() {
  local missing=0
  for cmd in tmux jq claude; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Missing dependency: $cmd"
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    log_error "Install missing dependencies and retry."
    exit 1
  fi
  log_info "Dependencies OK (tmux, jq, claude)"
}

# --- Session Ensure ---
ensure_session() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log_info "tmux session '$SESSION_NAME' already exists"
  else
    tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_ROOT"
    log_info "Created tmux session '$SESSION_NAME'"
  fi
}

# --- Kill stale heartbeat if running ---
kill_stale_heartbeat() {
  local pid_file="${ORCH_DIR}/heartbeat.pid"
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid=$(cat "$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
      log_warn "Killing stale heartbeat (PID $old_pid)"
      kill "$old_pid" 2>/dev/null || true
      local waited=0
      while kill -0 "$old_pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
        sleep 0.5
        waited=$((waited + 1))
      done
    fi
    rm -f "$pid_file"
  fi
}

# --- Start Heartbeat ---
start_heartbeat() {
  local heartbeat_script="${ORCH_DIR}/heartbeat.sh"
  if [[ ! -x "$heartbeat_script" ]]; then
    log_error "heartbeat.sh not found or not executable at: $heartbeat_script"
    exit 1
  fi

  kill_stale_heartbeat

  # Export vars for heartbeat
  export SESSION_NAME
  export ORCH_DIR

  nohup "$heartbeat_script" > "${ORCH_DIR}/heartbeat.log" 2>&1 &
  local hb_pid=$!
  sleep 1
  if kill -0 "$hb_pid" 2>/dev/null; then
    log_info "Heartbeat started (PID $hb_pid, session: $SESSION_NAME)"
  else
    log_error "Heartbeat failed to start. Check ${ORCH_DIR}/heartbeat.log"
    exit 1
  fi
}

# --- Init state files ---
init_state() {
  mkdir -p "${ORCH_DIR}/workers" "${ORCH_DIR}/results" "${ORCH_DIR}/inbox" "${ORCH_DIR}/channels"

  # Signal files
  touch "${ORCH_DIR}/.ready"
  rm -f "${ORCH_DIR}/.stop"

  # Init session.json if not exists
  if [[ ! -f "${ORCH_DIR}/session.json" ]]; then
    jq -n \
      --arg session "$SESSION_NAME" \
      --arg project "$(basename "$PROJECT_ROOT")" \
      --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        session_name: $session,
        project: $project,
        started: $started,
        status: "running",
        cycle_count: 0,
        workers: [],
        last_cycle: null
      }' > "${ORCH_DIR}/session.json"
    log_info "Initialized session.json"
  fi

  # Init config.json if not exists
  if [[ ! -f "${ORCH_DIR}/config.json" ]]; then
    cat > "${ORCH_DIR}/config.json" << 'EOF'
{
  "version": "1.0.0",
  "intervals": {
    "stuck_seconds": 30,
    "normal_seconds": 120,
    "idle_seconds": 300
  },
  "thresholds": {
    "stale_cycles": 3,
    "max_workers": 6,
    "turns_for_tmux": 25
  },
  "rules": {
    "enforce_code_review_after_turns": 30,
    "max_cycles_without_progress": 5
  },
  "pruning": {
    "max_age_days": 30,
    "auto_prune": true,
    "preserve_log_lines": 500
  }
}
EOF
    log_info "Created default config.json"
  fi
}

# --- Start Rate Limit Watchdog ---
start_watchdog() {
  local watchdog_script="${ORCH_DIR}/rate-limit-watchdog.sh"
  if [[ ! -x "$watchdog_script" ]]; then
    log_warn "rate-limit-watchdog.sh not found or not executable, skipping"
    return
  fi

  # Check if disabled in config
  local enabled
  enabled=$(jq -r '.watchdog.enabled // true' "${ORCH_DIR}/config.json" 2>/dev/null)
  if [[ "$enabled" == "false" ]]; then
    log_info "Rate Limit Watchdog disabled in config.json"
    return
  fi

  # Kill any existing watchdog
  if [[ -f "${ORCH_DIR}/watchdog.pid" ]]; then
    kill "$(cat "${ORCH_DIR}/watchdog.pid")" 2>/dev/null || true
    rm -f "${ORCH_DIR}/watchdog.pid"
    sleep 1
  fi

  export ORCH_DIR
  nohup "$watchdog_script" >> "${ORCH_DIR}/watchdog.log" 2>&1 &
  local wd_pid=$!
  sleep 1
  if kill -0 "$wd_pid" 2>/dev/null; then
    log_info "Rate Limit Watchdog started (PID $wd_pid)"
  else
    log_warn "Watchdog failed to start (non-critical, continuing without it)"
  fi
}

# --- Main ---
main() {
  log_info "=== Claude Code tmux Orchestrator ==="
  log_info "Project: $PROJECT_ROOT"
  log_info "Session: $SESSION_NAME"
  echo ""

  check_deps
  ensure_session
  init_state
  start_heartbeat
  start_watchdog

  echo ""
  log_info "=== Bootstrap complete ==="
  log_info ""
  log_info "Attach:  tmux attach -t $SESSION_NAME"
  log_info "Workers: ./_orchestrator/spawn-worker.sh w1 sonnet \"Your task here\""
  log_info "Stop:    touch ${ORCH_DIR}/.stop"
  log_info "Log:     tail -f ${ORCH_DIR}/heartbeat.log"
  log_info "Watchdog: tail -f ${ORCH_DIR}/watchdog.log"
}

main "$@"
