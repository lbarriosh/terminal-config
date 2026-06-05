#!/usr/bin/env bash
# Smoke tests for status_bar.sh
# Usage: bash tests/smoke_test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/status_bar.sh"
PASS=0; FAIL=0

_run() {
    local label="$1" input="$2" env_prefix="${3:-}"
    printf '\n=== %s ===\n' "$label"
    if [[ -n "$env_prefix" ]]; then
        env $env_prefix "$SCRIPT" <<< "$input"
    else
        "$SCRIPT" <<< "$input"
    fi
}

# 1) Anthropic API, working directory is not a git repo
_run "Anthropic API – no tasks, non-git dir" '{
  "session_id": "smoke-1",
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 61, "context_window_size": 200000},
  "cost": {"total_cost_usd": 0.8399}
}'

# 2) Bedrock ARN model – no cost, derive token count from total_input_tokens
_run "Bedrock ARN model – token count from total_input_tokens" '{
  "session_id": "smoke-2",
  "model": {"id": "anthropic.claude-3-5-sonnet-20241022-v2:0"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 43, "context_window_size": 200000, "total_input_tokens": 86000},
  "cost": {"total_cost_usd": 0}
}'

# 3) Bedrock with total_input_tokens provided directly
_run "Bedrock – total_input_tokens provided directly" '{
  "session_id": "smoke-3",
  "model": {"id": "anthropic.claude-sonnet-4-5:0"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 30, "total_input_tokens": 62000, "context_window_size": 200000},
  "cost": {"total_cost_usd": 0}
}'

# 4) Sub-cent cost → 4 decimal places
_run "Sub-cent cost (4 dp)" '{
  "session_id": "smoke-4",
  "model": {"display_name": "Claude Haiku 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 5},
  "cost": {"total_cost_usd": 0.0042}
}'

# 5) Normal cost → 2 decimal places
_run "Normal cost (2 dp)" '{
  "session_id": "smoke-5",
  "model": {"display_name": "Claude Opus 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 88},
  "cost": {"total_cost_usd": 3.1415}
}'

# 6) Empty JSON – graceful degradation
_run "Empty JSON payload" '{}'

# 7) With mock tasks (in_progress + pending) via session file
SESS_TMP="$(mktemp -d)"
SID="smoke-session-7"
cat > "$SESS_TMP/${SID}.json" <<'EOF'
{
  "tasks": {
    "t1": "completed",
    "t2": "completed",
    "t3": "in_progress",
    "t4": "pending",
    "t5": "pending"
  },
  "completions": [
    {"id": "t1", "timestamp": 1000},
    {"id": "t2", "timestamp": 1100}
  ]
}
EOF
_run "With mock tasks – 2 done / 1 in-progress / 2 pending" '{
  "session_id": "smoke-session-7",
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 61},
  "cost": {"total_cost_usd": 0.84}
}' "SESSIONS_DIR_OVERRIDE=$SESS_TMP"
rm -rf "$SESS_TMP"

# 8) All tasks complete – shows "All done!" (within 30s window)
SESS_TMP="$(mktemp -d)"
HIST_TMP="$(mktemp -d)"
SID="smoke-session-8"
NOW="$(date +%s)"
cat > "$SESS_TMP/${SID}.json" <<EOF
{
  "tasks": {"d1": "completed", "d2": "completed"},
  "completions": [
    {"id": "d1", "timestamp": $((NOW - 5))},
    {"id": "d2", "timestamp": $((NOW - 3))}
  ]
}
EOF
printf '{"completions":[{"id":"d1","timestamp":%d},{"id":"d2","timestamp":%d}],"ema_seconds":30}\n' \
    "$((NOW - 5))" "$((NOW - 3))" > "$HIST_TMP/history.json"
_run "All tasks complete – All done! message" '{
  "session_id": "smoke-session-8",
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 80},
  "cost": {"total_cost_usd": 0.12}
}' "SESSIONS_DIR_OVERRIDE=$SESS_TMP HISTORY_DIR_OVERRIDE=$HIST_TMP"
rm -rf "$SESS_TMP" "$HIST_TMP"

# 9) New fields: session_name, effort, thinking, dual duration
_run "New fields: session_name + effort:high + thinking + duration" '{
  "session_id": "smoke-9",
  "model": {"display_name": "Claude Sonnet 4.6"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 55},
  "cost": {"total_cost_usd": 0.07, "total_api_duration_ms": 45000, "total_duration_ms": 180000},
  "effort": {"level": "high"},
  "thinking": {"enabled": true},
  "session_name": "my-feature"
}'

printf '\n✓ All tests ran (exit 0 = no crashes)\n'
