#!/usr/bin/env bash
# Claude Code statusLine hook — outputs two lines:
#   [Model] repo @branch | ctx [bar] N% | $cost
#   Tasks [bar] N/N (~Xm left) | ✓N ⟳N ○N
#
# Requires: jq, git
# Debug: STATUS_BAR_DEBUG=1 dumps the raw JSON payload to /tmp/claude_status_debug.json
#
# Performance notes:
#   - The stdin payload is parsed by a single jq invocation (all fields + cost
#     classification + token count in one pass); the human-readable cost/token
#     formatting is done afterward with bash printf. No awk is used anywhere.
#   - Task state is read from a per-session file written by task_hooks.sh; the
#     status bar performs ZERO disk writes on every render.
#   - The task line merges the session file and history.json in a single jq pass
#     (--slurpfile + --slurpfile/--argjson) — one process, two file reads.
#   - Git info uses ONE call (rev-parse --show-toplevel --abbrev-ref HEAD): no
#     working-tree scan, so repo size does not affect cost. Dirty/untracked
#     state is intentionally not computed or shown.
set -euo pipefail
shopt -s extglob

# ─── Configuration ────────────────────────────────────────────────────────────
SESSIONS_DIR="${SESSIONS_DIR_OVERRIDE:-$HOME/.claude/status-bar/sessions}"
HISTORY_DIR="${HISTORY_DIR_OVERRIDE:-$HOME/.claude/status-bar}"
HISTORY_FILE="$HISTORY_DIR/history.json"
MIN_SAMPLES=3
DONE_DISPLAY_SECS=30
BAR_WIDTH=10

# ─── Dependencies ─────────────────────────────────────────────────────────────
_check_deps() {
    command -v jq >/dev/null 2>&1 || {
        printf '[status_bar] missing required tool: jq\n' >&2
        exit 1
    }
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

_build_bar() {
    local pct="$1" width="${2:-$BAR_WIDTH}"
    pct=$(( pct < 0 ? 0 : pct > 100 ? 100 : pct ))
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="[" i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty;  i++)); do bar+="░"; done
    bar+="]"
    printf '%s' "$bar"
}

_normalize_model() {
    local raw="$1"
    [[ -z "$raw" ]] && { printf 'Claude'; return; }
    # Already a display name (contains spaces)
    [[ "$raw" == *" "* ]] && { printf '%s' "$raw"; return; }
    # Strip Bedrock ARN wrapper: anthropic.claude-...:version
    local name="${raw#anthropic.}"
    name="${name%%:*}"
    # Strip date suffix (-YYYYMMDD) and trailing version (-v2, -v1) without spawning sed
    name="${name//-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/}"
    name="${name%-v*([0-9])}"
    case "$name" in
        claude-3-5-sonnet*) printf 'Claude 3.5 Sonnet' ;;
        claude-3-5-haiku*)  printf 'Claude 3.5 Haiku'  ;;
        claude-3-7-sonnet*) printf 'Claude 3.7 Sonnet' ;;
        claude-3-opus*)     printf 'Claude 3 Opus'     ;;
        claude-3-sonnet*)   printf 'Claude 3 Sonnet'   ;;
        claude-3-haiku*)    printf 'Claude 3 Haiku'    ;;
        claude-sonnet-4-6*) printf 'Claude Sonnet 4.6' ;;
        claude-sonnet-4-5*) printf 'Claude Sonnet 4.5' ;;
        claude-opus-4-8*)   printf 'Claude Opus 4.8'   ;;
        claude-opus-4-7*)   printf 'Claude Opus 4.7'   ;;
        claude-haiku-4-5*)  printf 'Claude Haiku 4.5'  ;;
        claude-sonnet-4*)   printf 'Claude Sonnet 4'   ;;
        claude-opus-4*)     printf 'Claude Opus 4'     ;;
        claude-haiku-4*)    printf 'Claude Haiku 4'    ;;
        *)  # generic: claude-foo-bar → Claude foo bar
            local out="${name//-/ }"
            printf '%s' "${out/#claude /Claude }" ;;
    esac
}

_format_tokens() {
    local n="$1"
    if   (( n >= 1000000 )); then
        printf '%d.%dM' "$(( n / 1000000 ))" "$(( (n % 1000000) / 100000 ))"
    elif (( n >= 1000 )); then
        printf '%dk' "$(( n / 1000 ))"
    else
        printf '%s' "$n"
    fi
}

_format_time() {
    # Expects an integer number of seconds.
    local secs="$1"
    if   (( secs < 10   )); then printf 'almost done'
    elif (( secs < 60   )); then printf '~%ds left' "$secs"
    elif (( secs < 3600 )); then
        local m=$(( secs / 60 )) s=$(( secs % 60 ))
        (( s == 0 )) && printf '~%dm left' "$m" \
                     || printf '~%dm %ds left' "$m" "$s"
    else
        local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
        (( m == 0 )) && printf '~%dh left' "$h" \
                     || printf '~%dh %dm left' "$h" "$m"
    fi
}

# ─── Task line ────────────────────────────────────────────────────────────────

_render_task_line() {
    local session_file="$1"
    [[ -f "$session_file" ]] || return 0

    local histarg
    if [[ -f "$HISTORY_FILE" ]]; then
        histarg=(--slurpfile hist "$HISTORY_FILE")
    else
        histarg=(--argjson hist '[]')
    fi

    # Single jq pass: session file + history.json — one process, zero writes
    local raw
    raw="$(jq -rn \
        --slurpfile sess "$session_file" \
        "${histarg[@]}" '
        ($sess[0]) as $s |
        (($hist | if type == "array" then .[0] else . end) // {}) as $h |
        ($s.tasks // {}) as $t |
        ([$t | to_entries[] | .value] | {
            completed: (map(select(. == "completed")) | length),
            in_prog:   (map(select(. == "in_progress")) | length),
            pending:   (map(select(. == "pending"))    | length)
        }) as $counts |
        ($counts.completed + $counts.in_prog + $counts.pending) as $total |
        (($s.completions // []) | if length > 0 then (map(.timestamp) | max) else 0 end) as $last |
        ($h.ema_seconds // "")          as $ema |
        ($h.completions // [] | length) as $count |
        ($total - $counts.completed)    as $remaining |
        (if ($ema != "" and $ema != null)
         then (($ema * $remaining) | floor)
         else "" end)                   as $est |
        "\($counts.completed)\t\($counts.in_prog)\t\($counts.pending)\t\($total)\t\($last)\t\($ema)\t\($count)\t\($est)"
    ' 2>/dev/null)" || return 0

    local completed in_prog pending total last_ts ema count est_secs
    IFS=$'\t' read -r completed in_prog pending total last_ts ema count est_secs <<< "$raw"
    [[ "$count"   =~ ^[0-9]+$ ]] || count=0
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

    [[ "$total" -eq 0 ]] && return 0

    # All done — show message for DONE_DISPLAY_SECS seconds then disappear
    if [[ "$completed" -eq "$total" ]]; then
        local now elapsed
        now="$(date +%s)"
        elapsed=$(( now - last_ts ))
        if (( elapsed <= DONE_DISPLAY_SECS )); then
            printf 'All done! (%d tasks)' "$total"
        fi
        return 0
    fi

    local pct=$(( total > 0 ? completed * 100 / total : 0 ))
    local bar; bar="$(_build_bar "$pct")"

    local time_str=""
    if [[ -n "$ema" && -n "$est_secs" && "$count" -ge "$MIN_SAMPLES" ]]; then
        time_str="$(_format_time "$est_secs")"
    fi

    local line="Tasks $bar $completed/$total"
    [[ -n "$time_str" ]] && line+=" ($time_str)"
    line+=" | ✅$completed 🔄$in_prog 🕐$pending"

    printf '%s' "$line"
}

# ─── Payload / git extraction ─────────────────────────────────────────────────
# These two helpers return their results by assigning into the caller's `local`
# variables via bash dynamic scoping (no subshell, no stdout parsing). The caller
# (main) MUST pre-declare the listed output variables `local`; the helpers assign
# them without `local` and keep only their own internal temporaries `local`.

# Decodes the Claude Code stdin JSON with one jq pass.
# Output variables (declared local by the caller):
#   model_raw cwd pct cost cost_class token_count session_id
_parse_payload() {
    local input="$1"

    # Extract every stdin field with ONE jq pass. Order of emitted lines:
    #   model_raw, cwd, pct, cost, cost_class, token_count, session_id
    local payload
    payload="$(jq -r '
        (.cost.total_cost_usd // .session.cost_usd // .usage.total_cost_usd // 0) as $cost |
        ((.context_window.used_percentage // 0) | floor)                          as $pct  |
        (.context_window.total_input_tokens // .context_window.used_tokens // 0)  as $used |
        (.context_window.context_window_size // .context_window.total_tokens
          // .context_window.max_tokens // 0)                                     as $total|
        (if   $used > 0                       then $used
         elif ($total > 0 and $pct > 0)       then (($pct * $total / 100) | floor)
         else 0 end)                                                              as $tok  |
        ((.model | objects | (.display_name // .id)) // (.model | strings) // ""),
        (.workspace.current_dir // ""),
        $pct,
        $cost,
        (if $cost > 0 then (if $cost < 0.01 then "sub" else "normal" end) else "none" end),
        $tok,
        (.session_id // "")
    ' <<< "$input" 2>/dev/null)" || payload=""

    # shellcheck disable=SC2034  # assigned into the caller's locals (dynamic scope)
    {
        IFS= read -r model_raw
        IFS= read -r cwd
        IFS= read -r pct
        IFS= read -r cost
        IFS= read -r cost_class
        IFS= read -r token_count
        IFS= read -r session_id
    } <<< "$payload" || true

    # Guards: ensure numerics are sane
    [[ "$pct"         =~ ^[0-9]+$          ]] || pct="0"
    [[ "$cost"        =~ ^[0-9]+\.?[0-9]*$ ]] || cost="0"
    [[ "$token_count" =~ ^[0-9]+$          ]] || token_count="0"
    return 0
}

# Computes git repo/branch with a SINGLE git invocation (no disk writes, no
# working-tree scan). `git rev-parse --show-toplevel --abbrev-ref HEAD` emits
# the repo toplevel on line 1 and the branch name on line 2; a detached HEAD
# prints "HEAD", and a repo with no commits (unborn branch) makes the whole
# command fail — in that case we fall back to the cwd basename with no branch.
# `dirty` is left untouched (always empty) so callers needing the variable for
# line assembly keep working without change.
# Output variables (declared local by the caller):
#   repo_name branch dirty
# shellcheck disable=SC2034  # repo_name/branch/dirty are the caller's locals (dynamic scope)
_git_info() {
    local cwd="$1"
    local gitout
    if [[ -n "${cwd:-}" ]] && gitout="$(git -C "$cwd" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)"; then
        local toplevel="${gitout%%$'\n'*}"
        repo_name="${toplevel##*/}"
        branch="${gitout#*$'\n'}"
    else
        repo_name="${cwd:-unknown}"
        repo_name="${repo_name##*/}"
        [[ -z "$repo_name" || "$repo_name" == "." ]] && repo_name="unknown"
    fi
    return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    _check_deps

    local input=""
    IFS= read -r -d '' input || true

    if [[ "${STATUS_BAR_DEBUG:-0}" == "1" ]]; then
        printf '%s\n' "$input" > /tmp/claude_status_debug.json
    fi

    # ── Parse the stdin payload (jq) ───────────────────────────────────────────
    local model_raw="" cwd="" pct="0" cost="0" cost_class="none" token_count="0" session_id=""
    _parse_payload "$input"

    local model; model="$(_normalize_model "${model_raw:-}")"

    # ── Git info (one invocation, no disk writes) ─────────────────────────────
    local repo_name="" branch="" dirty=""
    _git_info "$cwd"

    # ── Context bar ───────────────────────────────────────────────────────────
    local ctx_bar; ctx_bar="$(_build_bar "$pct")"

    # ── Cost / token field ────────────────────────────────────────────────────
    local cost_field=""
    case "$cost_class" in
        normal) cost_field="$(printf '$%.2f' "$cost")" ;;
        sub)    cost_field="$(printf '$%.4f' "$cost")" ;;
        none)   [[ "$token_count" -gt 0 ]] && cost_field="~$(_format_tokens "$token_count") tok" ;;
    esac

    # ── Line 1 ────────────────────────────────────────────────────────────────
    local line1="[${model}] ${repo_name}"
    [[ -n "$branch" ]] && line1+=" @${branch}${dirty}"
    line1+=" | ctx ${ctx_bar} ${pct}%"
    [[ -n "$cost_field" ]] && line1+=" | $cost_field"
    printf '%s\n' "$line1"

    # ── Line 2: task progress ─────────────────────────────────────────────────
    local session_file="$SESSIONS_DIR/${session_id}.json"
    local task_line; task_line="$(_render_task_line "$session_file")" || true
    if [[ -n "$task_line" ]]; then printf '%s\n' "$task_line"; fi
    return 0
}

main
