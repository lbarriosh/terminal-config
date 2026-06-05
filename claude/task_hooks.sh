#!/usr/bin/env bash
# Claude Code hook handler — maintains per-session task state and global EMA history.
#
# Registered for: SessionStart, TaskCreated, TaskCompleted, PostToolUse(TaskUpdate), SessionEnd
#
# Writes:
#   ~/.claude/status-bar/sessions/<session_id>.json  — per-session task state
#   ~/.claude/status-bar/history.json                — global EMA completion history
#
# Requires: jq
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SESSIONS_DIR="${SESSIONS_DIR_OVERRIDE:-$HOME/.claude/status-bar/sessions}"
HISTORY_DIR="${HISTORY_DIR_OVERRIDE:-$HOME/.claude/status-bar}"
HISTORY_FILE="$HISTORY_DIR/history.json"
EMA_ALPHA="0.3"
MAX_HISTORY=200
STATUS_BAR_SESSION_TTL_DAYS="${STATUS_BAR_SESSION_TTL_DAYS:-1}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Atomic write: jq doc → tmp → mv
# Args: $1=file $2=task_id $3=status $4=timestamp (empty string = no completion record)
_upsert_task() {
    local session_file="$1" task_id="$2" status="$3" timestamp="${4:-}"
    mkdir -p "$(dirname "$session_file")" 2>/dev/null || true

    local existing='{}'
    [[ -f "$session_file" ]] && existing="$(< "$session_file")"

    local new_doc
    new_doc="$(jq -nc \
        --argjson doc    "$existing" \
        --arg     id     "$task_id" \
        --arg     status "$status" \
        --argjson ts     "${timestamp:-null}" '
        $doc
        | .tasks[$id] = $status
        | if $ts != null
          then .completions = ((.completions // []) + [{id: $id, timestamp: $ts}])
          else .
          end
    ')" || return 0

    printf '%s\n' "$new_doc" > "${session_file}.tmp" \
        && mv "${session_file}.tmp" "$session_file" 2>/dev/null || true
}

# Update global EMA history with a new completion. Last-write-wins across sessions (acceptable
# for a soft estimate). Deduplicates by task ID so re-fired events don't corrupt the EMA.
# Args: $1=task_id $2=unix_timestamp
_update_global_ema() {
    local task_id="$1" now="$2"
    mkdir -p "$HISTORY_DIR" 2>/dev/null || true

    local max_history="$MAX_HISTORY"
    if [[ -n "${STATUS_BAR_MAX_HISTORY:-}" ]]; then
        if [[ "${STATUS_BAR_MAX_HISTORY}" =~ ^[1-9][0-9]*$ ]]; then
            max_history="$STATUS_BAR_MAX_HISTORY"
        fi
    fi

    local histarg
    if [[ -f "$HISTORY_FILE" ]]; then
        histarg=(--slurpfile hist "$HISTORY_FILE")
    else
        histarg=(--argjson hist '[]')
    fi

    local new_doc
    new_doc="$(jq -nrc \
        --arg     id    "$task_id" \
        "${histarg[@]}" \
        --argjson now   "$now" \
        --argjson alpha "$EMA_ALPHA" \
        --argjson max   "$max_history" '
        (($hist | if type == "array" then .[0] else . end) // {}) as $h |
        ($h.completions // [])  as $comps |
        ($comps | map(.id))     as $known |
        (if ([$known[] | . == $id] | any) then $comps
         else ($comps + [{id: $id, timestamp: $now}] | sort_by(.timestamp))[-$max:]
         end)                   as $allc |
        (reduce range(1; ($allc | length)) as $i (
             null;
             . as $ema |
             ($allc[$i].timestamp - $allc[$i-1].timestamp) as $raw |
             if $raw < 0 then $ema
             else
                 (if $raw > 3600 then 3600 else $raw end) as $delta |
                 if $ema == null then $delta
                 else $alpha * $delta + (1 - $alpha) * $ema
                 end
             end
         ))                     as $ema |
        {completions: $allc, ema_seconds: $ema}
    ' 2>/dev/null)" || return 0

    printf '%s\n' "$new_doc" > "${HISTORY_FILE}.tmp" \
        && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE" 2>/dev/null || true
}

# ─── Event handlers ───────────────────────────────────────────────────────────

_on_session_start() {
    [[ -d "$SESSIONS_DIR" ]] || return 0
    # -mtime +N means "modified more than (N+1)*24h ago"; TTL_DAYS-1 maps: TTL=1 → +0, TTL=7 → +6
    find "$SESSIONS_DIR" -name '*.json' -mtime +"$((STATUS_BAR_SESSION_TTL_DAYS - 1))" \
        -delete 2>/dev/null || true
}

_on_task_created() {
    local input="$1" session_file="$2"
    local task_id
    task_id="$(jq -r '.task_id // ""' <<< "$input")"
    [[ -z "$task_id" ]] && return 0
    _upsert_task "$session_file" "$task_id" "pending" ""
}

_on_task_completed() {
    local input="$1" session_file="$2"
    local task_id now
    task_id="$(jq -r '.task_id // ""' <<< "$input")"
    [[ -z "$task_id" ]] && return 0
    now="$(date +%s)"
    _upsert_task "$session_file" "$task_id" "completed" "$now"
    _update_global_ema "$task_id" "$now"
}

_on_pre_tool_use() {
    local input="$1" session_file="$2"
    local tool_name
    tool_name="$(jq -r '.tool_name // ""' <<< "$input")"

    case "$tool_name" in
        TaskCreate)
            # Real task ID is not yet assigned at PreToolUse time — use the tool_use_id as a
            # stable placeholder. It will be replaced by the real numeric ID on the first
            # TaskUpdate for this task. Tasks that go straight to completed without an
            # in_progress step will be caught by the TaskUpdate(completed) branch below.
            local placeholder_id
            placeholder_id="$(jq -r '.tool_use_id // ""' <<< "$input")"
            [[ -z "$placeholder_id" ]] && return 0
            _upsert_task "$session_file" "$placeholder_id" "pending" ""
            ;;
        TaskUpdate)
            local new_status task_id
            new_status="$(jq -r '.tool_input.status // ""' <<< "$input")"
            task_id="$(jq -r '.tool_input.taskId // ""' <<< "$input")"
            [[ -z "$task_id" ]] && return 0
            case "$new_status" in
                in_progress)
                    _upsert_task "$session_file" "$task_id" "in_progress" ""
                    ;;
                completed)
                    local now; now="$(date +%s)"
                    _upsert_task "$session_file" "$task_id" "completed" "$now"
                    _update_global_ema "$task_id" "$now"
                    ;;
                deleted)
                    local existing='{}' new_doc
                    [[ -f "$session_file" ]] && existing="$(< "$session_file")"
                    new_doc="$(jq -nc \
                        --argjson doc "$existing" \
                        --arg     id  "$task_id" '
                        $doc | .tasks = (.tasks // {} | del(.[$id]))
                    ')" || return 0
                    printf '%s\n' "$new_doc" > "${session_file}.tmp" \
                        && mv "${session_file}.tmp" "$session_file" 2>/dev/null || true
                    ;;
            esac
            ;;
    esac
}

_on_session_end() {
    local session_file="$1"
    rm -f "$session_file" 2>/dev/null || true
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local input=""
    IFS= read -r -d '' input || true

    local event session_id
    event="$(jq -r '.hook_event_name // ""' <<< "$input")"
    session_id="$(jq -r '.session_id // ""' <<< "$input")"

    [[ -z "$event" ]] && exit 0

    # session_id is documented as present on every hook event, but _on_session_start
    # doesn't use it — guard per-event so a missing session_id never silently skips pruning.
    local session_file=""
    [[ -n "$session_id" ]] && session_file="$SESSIONS_DIR/${session_id}.json"

    case "$event" in
        SessionStart)  _on_session_start ;;
        # TaskCreated/TaskCompleted are in the docs but don't fire in practice (v2.1.x);
        # PreToolUse on TaskCreate/TaskUpdate is what actually works.
        TaskCreated)   [[ -n "$session_file" ]] || exit 0; _on_task_created   "$input" "$session_file" ;;
        TaskCompleted) [[ -n "$session_file" ]] || exit 0; _on_task_completed  "$input" "$session_file" ;;
        PreToolUse)    [[ -n "$session_file" ]] || exit 0; _on_pre_tool_use    "$input" "$session_file" ;;
        SessionEnd)    [[ -n "$session_file" ]] || exit 0; _on_session_end     "$session_file" ;;
    esac
}

main
