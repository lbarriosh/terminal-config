#!/usr/bin/env bash
# Tests for task_hooks.sh — verifies write-path correctness.
# Each case calls _fresh_dirs to get isolated temp dirs; no prior-case state leaks forward.
#
# Usage:
#   bash tests/task_hooks_test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/task_hooks.sh"
PASS=0; FAIL=0

CLEAN=()
trap 'rm -rf "${CLEAN[@]}"' EXIT

_fresh_dirs() {
    SESS_DIR="$(mktemp -d)"; CLEAN+=("$SESS_DIR")
    HIST_DIR="$(mktemp -d)"; CLEAN+=("$HIST_DIR")
}

feed() {
    printf '%s' "$1" \
        | env SESSIONS_DIR_OVERRIDE="$SESS_DIR" HISTORY_DIR_OVERRIDE="$HIST_DIR" "$SCRIPT"
}

jq_field() { jq -r "$2" "$1" 2>/dev/null; }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$label"
        diff <(printf '%s' "$expected") <(printf '%s' "$actual") | sed 's/^/      /' || true
    fi
}

# Portable mtime backdating — macOS BSD date or GNU date (Linux)
_backdate() {
    local file="$1" days="$2"
    if date -v-1d > /dev/null 2>&1; then
        touch -t "$(date -v-"${days}"d '+%Y%m%d%H%M')" "$file"
    else
        touch -d "${days} days ago" "$file"
    fi
}

# ─── Case 1: PreToolUse(TaskCreate) writes pending status using tool_use_id ───
_fresh_dirs
feed '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"TaskCreate","tool_input":{"subject":"Do thing"},"tool_use_id":"tu-abc123"}'
check "PreToolUse(TaskCreate) → pending" "pending" "$(jq_field "$SESS_DIR/s1.json" '.tasks["tu-abc123"]')"

# ─── Case 2: TaskCompleted transitions status, appends completion, writes history.json ───
_fresh_dirs
printf '{"tasks":{"t1":"pending"},"completions":[]}\n' > "$SESS_DIR/s1.json"
feed '{"hook_event_name":"TaskCompleted","session_id":"s1","task_id":"t1","task_subject":"Do thing"}'
check "TaskCompleted → completed"              "completed" "$(jq_field "$SESS_DIR/s1.json" '.tasks.t1')"
check "TaskCompleted → completions count"      "1"         "$(jq_field "$SESS_DIR/s1.json" '.completions | length')"
check "TaskCompleted → completion id"          "t1"        "$(jq_field "$SESS_DIR/s1.json" '.completions[0].id')"
check "TaskCompleted → history.json written"   "1"         "$(jq_field "$HIST_DIR/history.json" '.completions | length')"

# ─── Case 3: PreToolUse(TaskUpdate, in_progress) transitions status ──────────
_fresh_dirs
printf '{"tasks":{"t1":"pending"},"completions":[]}\n' > "$SESS_DIR/s1.json"
feed '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"TaskUpdate","tool_input":{"taskId":"t1","status":"in_progress"}}'
check "TaskUpdate in_progress → in_progress" "in_progress" "$(jq_field "$SESS_DIR/s1.json" '.tasks.t1')"

# ─── Case 4: PreToolUse(TaskUpdate, completed) transitions to completed ──────
_fresh_dirs
printf '{"tasks":{"t1":"pending"},"completions":[]}\n' > "$SESS_DIR/s1.json"
feed '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"TaskUpdate","tool_input":{"taskId":"t1","status":"completed"}}'
check "TaskUpdate completed → completed" "completed" "$(jq_field "$SESS_DIR/s1.json" '.tasks.t1')"

# ─── Case 5: _upsert_task creates file from scratch ──────────────────────────
_fresh_dirs
feed '{"hook_event_name":"TaskCreated","session_id":"s2","task_id":"t1","task_subject":"New"}'
check "upsert creates file"  "1"       "$([ -f "$SESS_DIR/s2.json" ] && echo 1 || echo 0)"
check "upsert valid JSON"    "pending" "$(jq_field "$SESS_DIR/s2.json" '.tasks.t1')"

# ─── Case 6: SessionEnd deletes session file ─────────────────────────────────
_fresh_dirs
printf '{"tasks":{},"completions":[]}\n' > "$SESS_DIR/s1.json"
feed '{"hook_event_name":"SessionEnd","session_id":"s1"}'
check "SessionEnd deletes file" "0" "$([ -f "$SESS_DIR/s1.json" ] && echo 1 || echo 0)"

# ─── Case 7: SessionStart prunes stale files, keeps fresh ────────────────────
_fresh_dirs
printf '{}' > "$SESS_DIR/stale.json"
_backdate "$SESS_DIR/stale.json" 2   # 2 days old → beyond default TTL of 1 day
printf '{}' > "$SESS_DIR/fresh.json" # just created → within TTL
feed '{"hook_event_name":"SessionStart","session_id":"new-session"}'
check "SessionStart prunes stale" "0" "$([ -f "$SESS_DIR/stale.json" ] && echo 1 || echo 0)"
check "SessionStart keeps fresh"  "1" "$([ -f "$SESS_DIR/fresh.json" ] && echo 1 || echo 0)"

# ─── Result ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
