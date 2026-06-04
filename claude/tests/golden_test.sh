#!/usr/bin/env bash
# Golden-output tests for status_bar.sh
#
# Unlike smoke_test.sh (which only checks that the script doesn't crash), this
# asserts the EXACT bytes the script prints for a set of deterministic cases, so
# a refactor can be validated without diffing against a saved copy of the old
# script.
#
# Usage:
#   bash tests/golden_test.sh            # assert inlined expected outputs
#   bash tests/golden_test.sh --bless    # print actual outputs for re-inlining
#
# All cases isolate SESSIONS_DIR/HISTORY_DIR so ambient ~/.claude state never leaks
# in, and the git case neutralises host git config so it stays deterministic.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/status_bar.sh"
BLESS=0
[[ "${1:-}" == "--bless" ]] && BLESS=1

PASS=0; FAIL=0
EMPTY="$(mktemp -d)"          # empty sessions + history dir for line-1-only cases
CLEAN=("$EMPTY")
trap 'rm -rf "${CLEAN[@]}"' EXIT

# render <json> <sessions_dir> <hist_dir> [extra env KEY=VAL ...]
render() {
    local json="$1" sd="$2" hd="$3"; shift 3
    printf '%s' "$json" \
        | env SESSIONS_DIR_OVERRIDE="$sd" HISTORY_DIR_OVERRIDE="$hd" "$@" "$SCRIPT"
}

# check <label> <expected> <actual>
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$BLESS" == "1" ]]; then
        printf '### %s\n%s\n---\n' "$label" "$actual"
        return 0
    fi
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$label"
        diff <(printf '%s' "$expected") <(printf '%s' "$actual") | sed 's/^/      /' || true
    fi
}

# Builds a deterministic git repo at <dir>/repo (fixed basename "repo"),
# branch "testbranch", with 1 staged + 1 unstaged + 1 untracked file. The dirty
# files exist on purpose: the status line must NOT report them (it does a single
# rev-parse, no working-tree scan), so case H doubles as a regression guard.
# Echoes the repo path. Host git config is isolated so defaults are predictable.
make_git_repo() {
    local root repo; root="$(mktemp -d)"; CLEAN+=("$root"); repo="$root/repo"
    mkdir -p "$repo"
    (
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        cd "$repo"
        git init -q
        git symbolic-ref HEAD refs/heads/testbranch
        git config user.email test@example.com
        git config user.name  Test
        git config commit.gpgsign false
        printf 'a\n' > tracked.txt
        git add tracked.txt
        git commit -qm init
        printf 'b\n' >> tracked.txt    # unstaged modification  → !1
        printf 'c\n' > staged.txt
        git add staged.txt             # staged addition        → +1
        printf 'd\n' > untracked.txt   # untracked              → ?1
    ) >/dev/null 2>&1
    printf '%s' "$repo"
}

# Creates a temp dir holding a session JSON file; echoes the dir path.
# The dir is used as SESSIONS_DIR_OVERRIDE; status_bar.sh appends /<session_id>.json.
make_session() {
    local session_id="$1" tasks_json="$2"
    local dir; dir="$(mktemp -d)"; CLEAN+=("$dir")
    printf '%s\n' "$tasks_json" > "$dir/${session_id}.json"
    printf '%s' "$dir"
}

# Creates a temp dir holding history.json; echoes the dir.
make_history() {
    local dir; dir="$(mktemp -d)"; CLEAN+=("$dir")
    printf '%s\n' "$1" > "$dir/history.json"
    printf '%s' "$dir"
}

# ─── Line-1 formatting cases (non-git, no tasks) ───────────────────────────────

check "A: normal cost (2dp), display-name model" \
'[Claude Sonnet 4] tmp | ctx [██████░░░░] 61% | $0.84' \
"$(render '{"session_id":"s-a","model":{"display_name":"Claude Sonnet 4"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":61,"context_window_size":200000},"cost":{"total_cost_usd":0.8399}}' "$EMPTY" "$EMPTY")"

check "B: sub-cent cost (4dp)" \
'[Claude Haiku 4] tmp | ctx [░░░░░░░░░░] 5% | $0.0042' \
"$(render '{"session_id":"s-b","model":{"display_name":"Claude Haiku 4"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":5},"cost":{"total_cost_usd":0.0042}}' "$EMPTY" "$EMPTY")"

check "C: Bedrock ARN -> token fallback" \
'[Claude 3.5 Sonnet] tmp | ctx [████░░░░░░] 43% | ~86k tok' \
"$(render '{"session_id":"s-c","model":{"id":"anthropic.claude-3-5-sonnet-20241022-v2:0"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":43,"context_window_size":200000,"total_input_tokens":86000},"cost":{"total_cost_usd":0}}' "$EMPTY" "$EMPTY")"

check "D: Bedrock total_input_tokens direct" \
'[Claude Sonnet 4.5] tmp | ctx [███░░░░░░░] 30% | ~62k tok' \
"$(render '{"session_id":"s-d","model":{"id":"anthropic.claude-sonnet-4-5:0"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":30,"total_input_tokens":62000,"context_window_size":200000},"cost":{"total_cost_usd":0}}' "$EMPTY" "$EMPTY")"

check "E: bare-string model + no cost field" \
'[Claude Opus 4.8] tmp | ctx [█░░░░░░░░░] 12%' \
"$(render '{"session_id":"s-e","model":"claude-opus-4-8-20250101","workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":12},"cost":{"total_cost_usd":0}}' "$EMPTY" "$EMPTY")"

check "F: empty JSON payload" \
'[Claude] unknown | ctx [░░░░░░░░░░] 0%' \
"$(render '{}' "$EMPTY" "$EMPTY")"

check "G: pct clamp >100" \
'[Claude x] tmp | ctx [██████████] 150%' \
"$(render '{"session_id":"s-g","model":{"id":"claude-x"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":150},"cost":{"total_cost_usd":0}}' "$EMPTY" "$EMPTY")"

# ─── Git fixture (branch + dirty counts) ───────────────────────────────────────

GIT_REPO="$(make_git_repo)"
check "H: git repo @testbranch (dirty state not shown)" \
'[Claude Sonnet 4] repo @testbranch | ctx [█████░░░░░] 50% | $2.00' \
"$(render '{"session_id":"s-h","model":{"display_name":"Claude Sonnet 4"},"workspace":{"current_dir":"'"$GIT_REPO"'"},"context_window":{"used_percentage":50},"cost":{"total_cost_usd":2}}' "$EMPTY" "$EMPTY" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)"

# ─── Task line cases ───────────────────────────────────────────────────────────

# I: tasks present, fewer than MIN_SAMPLES completions, fresh history → calculating
SID_I="test-session-i"
SESS_I="$(make_session "$SID_I" '{"tasks":{"a":"completed","b":"completed","c":"in_progress","d":"pending","e":"pending"},"completions":[{"id":"a","timestamp":1000},{"id":"b","timestamp":1100}]}')"
HIST_I="$(mktemp -d)"; CLEAN+=("$HIST_I")
check "I: task line calculating..." \
'[Claude Sonnet 4] tmp | ctx [████░░░░░░] 40% | $0.50
Tasks [████░░░░░░] 2/5 | ✅2 🔄1 🕐2' \
"$(render '{"session_id":"'"$SID_I"'","model":{"display_name":"Claude Sonnet 4"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":40},"cost":{"total_cost_usd":0.5}}' "$SESS_I" "$HIST_I")"

# J: history seeded with ema=60, remaining=2 → est=120s → "~2m left"
SID_J="test-session-j"
SESS_J="$(make_session "$SID_J" '{"tasks":{"h1":"completed","h2":"completed","h3":"completed","i1":"in_progress","p1":"pending"},"completions":[{"id":"h1","timestamp":1000},{"id":"h2","timestamp":1100},{"id":"h3","timestamp":1200}]}')"
HIST_J="$(make_history '{"completions":[{"id":"h1","timestamp":1000},{"id":"h2","timestamp":1100},{"id":"h3","timestamp":1200}],"ema_seconds":60}')"
check "J: task line EMA ~2m left" \
'[Claude Sonnet 4] tmp | ctx [██████░░░░] 60% | $0.50
Tasks [██████░░░░] 3/5 (~2m left) | ✅3 🔄1 🕐1' \
"$(render '{"session_id":"'"$SID_J"'","model":{"display_name":"Claude Sonnet 4"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":60},"cost":{"total_cost_usd":0.5}}' "$SESS_J" "$HIST_J")"

# K: all tasks complete, last completion within DONE_DISPLAY_SECS → "All done!"
NOW="$(date +%s)"
SID_K="test-session-k"
SESS_K="$(make_session "$SID_K" '{"tasks":{"d1":"completed","d2":"completed"},"completions":[{"id":"d1","timestamp":'"$((NOW - 5))"'},{"id":"d2","timestamp":'"$((NOW - 3))"'}]}')"
HIST_K="$(make_history '{"completions":[{"id":"d1","timestamp":'"$((NOW - 5))"'},{"id":"d2","timestamp":'"$((NOW - 3))"'}],"ema_seconds":30}')"
check "K: all done message" \
'[Claude Sonnet 4] tmp | ctx [████████░░] 80% | $0.12
All done! (2 tasks)' \
"$(render '{"session_id":"'"$SID_K"'","model":{"display_name":"Claude Sonnet 4"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":80},"cost":{"total_cost_usd":0.12}}' "$SESS_K" "$HIST_K")"

# ─── Result ────────────────────────────────────────────────────────────────────
if [[ "$BLESS" == "1" ]]; then
    printf '\n(bless mode: copy each block above into the matching EXPECTED_* literal)\n'
    exit 0
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
