#!/bin/bash
# common.sh — shared bash utilities for nullexit scripts

# ─── Formatting ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step() { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✗ $*${NC}"; }
die()  { echo -e "\n  ${RED}✗ $*${NC}\n"; exit 1; }

# ─── Helper Functions ────────────────────────────────────────────────────────

# Pure-bash timeout (no dependency on GNU coreutils' timeout)
# Runs a command with a safety cutoff so a wedged daemon can't hang the script.
run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ $# -eq 0 ]; then return 1; fi
  
  "$@" &
  local cmd_pid=$!
  CURRENT_BG_PID="$cmd_pid"
  
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>> output.log; then
      echo -e "\n[Timeout] Command '$*' exceeded $timeout_sec seconds. Terminating..." >&2
      kill -15 "$cmd_pid" 2>> output.log || true
      sleep 2
      if kill -0 "$cmd_pid" 2>> output.log; then
        kill -9 "$cmd_pid" 2>> output.log || true
      fi
    fi
  ) &
  local watcher_pid=$!
  
  # Disable set -e temporarily to capture exit status of wait
  set +e
  wait "$cmd_pid" 2>> output.log
  local exit_status=$?
  set -e
  
  # Kill the watcher since the command finished
  kill "$watcher_pid" 2>> output.log && wait "$watcher_pid" 2>> output.log || true
  
  CURRENT_BG_PID=""
  return "$exit_status"
}
