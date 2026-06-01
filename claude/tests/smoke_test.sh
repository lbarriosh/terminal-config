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
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 61, "total_tokens": 200000},
  "cost": {"total_cost_usd": 0.8399}
}'

# 2) Bedrock ARN model – no cost, derive token count from %
_run "Bedrock ARN model – token count fallback" '{
  "model": {"id": "anthropic.claude-3-5-sonnet-20241022-v2:0"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 43, "total_tokens": 200000},
  "cost": {"total_cost_usd": 0}
}'

# 3) Bedrock with used_tokens directly provided
_run "Bedrock – used_tokens provided directly" '{
  "model": {"id": "anthropic.claude-sonnet-4-5:0"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 30, "used_tokens": 62000, "total_tokens": 200000},
  "cost": {"total_cost_usd": 0}
}'

# 4) Sub-cent cost → 4 decimal places
_run "Sub-cent cost (4 dp)" '{
  "model": {"display_name": "Claude Haiku 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 5},
  "cost": {"total_cost_usd": 0.0042}
}'

# 5) Normal cost → 2 decimal places
_run "Normal cost (2 dp)" '{
  "model": {"display_name": "Claude Opus 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 88},
  "cost": {"total_cost_usd": 3.1415}
}'

# 6) Empty JSON – graceful degradation
_run "Empty JSON payload" '{}'

# 7) With mock tasks (in_progress + pending)
TASKS_TMP="$(mktemp -d)"
cat > "$TASKS_TMP/session.json" <<'EOF'
[
  {"id":"t1","status":"completed","title":"Write tests"},
  {"id":"t2","status":"completed","title":"Fix bug"},
  {"id":"t3","status":"in_progress","title":"Deploy"},
  {"id":"t4","status":"pending","title":"Notify team"},
  {"id":"t5","status":"pending","title":"Update docs"}
]
EOF
_run "With mock tasks – 2 done / 1 in-progress / 2 pending" '{
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 61},
  "cost": {"total_cost_usd": 0.84}
}' "TASKS_DIR_OVERRIDE=$TASKS_TMP"
rm -rf "$TASKS_TMP"

# 8) All tasks complete – shows "All done!" (within 30s window)
TASKS_TMP="$(mktemp -d)"
HIST_TMP="$(mktemp -d)"
cat > "$TASKS_TMP/done.json" <<'EOF'
[
  {"id":"d1","status":"completed","title":"One"},
  {"id":"d2","status":"completed","title":"Two"}
]
EOF
# Pre-seed history with completion timestamps in the past 10s
NOW="$(date +%s)"
printf '{"completions":[{"id":"d1","timestamp":%d},{"id":"d2","timestamp":%d}],"ema_seconds":30}\n' \
    "$((NOW - 5))" "$((NOW - 3))" > "$HIST_TMP/history.json"
_run "All tasks complete – All done! message" '{
  "model": {"display_name": "Claude Sonnet 4"},
  "workspace": {"current_dir": "/tmp"},
  "context_window": {"used_percentage": 80},
  "cost": {"total_cost_usd": 0.12}
}' "TASKS_DIR_OVERRIDE=$TASKS_TMP HISTORY_DIR_OVERRIDE=$HIST_TMP"
rm -rf "$TASKS_TMP" "$HIST_TMP"

printf '\n✓ All tests ran (exit 0 = no crashes)\n'
