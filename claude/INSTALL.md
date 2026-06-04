# Claude Code Status Bar

`status_bar.sh` is a Claude Code `statusLine` hook that renders two lines:

```
[Claude Sonnet 4] payments-service @main | ctx [██████████] 61% | $0.84
Tasks [██████░░░░] 6/10 (~4m left) | ✓6 ⟳1 ○3
```

**Line 1** — model, git repo/branch, context window usage, cost (or token count on Bedrock).  
**Line 2** — task progress bar with EMA-based time estimate (hidden when no tasks exist).

## Prerequisites

- `jq` — `brew install jq` / `apt install jq`
- `git` — present on every macOS/Linux system

## Installation

1. **Make the scripts executable** (already done if you cloned this repo):

   ```bash
   chmod +x /path/to/terminal-config/claude/status_bar.sh
   chmod +x /path/to/terminal-config/claude/task_hooks.sh
   ```

2. **Register both scripts in `~/.claude/settings.json`**:

   Open `~/.claude/settings.json` and add the `hooks` and `statusLine` keys. Replace
   `/path/to/terminal-config` with the actual path on your machine.

   If your `settings.json` already has other keys, merge these blocks in alongside them —
   do **not** replace the whole file:

   ```json
   {
     "hooks": {
       "SessionStart": [
         { "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ],
       "PreToolUse": [
         { "matcher": "TaskCreate", "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] },
         { "matcher": "TaskUpdate", "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ],
       "PostToolUse": [
         { "matcher": "TaskCreate", "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] },
         { "matcher": "TaskUpdate", "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ],
       "TaskCreated": [
         { "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ],
       "TaskCompleted": [
         { "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ],
       "SessionEnd": [
         { "hooks": [{ "type": "command", "command": "/path/to/terminal-config/claude/task_hooks.sh" }] }
       ]
     },
     "statusLine": {
       "type": "command",
       "command": "/path/to/terminal-config/claude/status_bar.sh",
       "padding": 2,
       "refreshInterval": 30
     }
   }
   ```

   > **Note on hook compatibility:** `PreToolUse(TaskCreate/TaskUpdate)` and `PostToolUse(TaskCreate/TaskUpdate)` are the hooks that actually fire in Claude Code v2.1.x. The `TaskCreated` and `TaskCompleted` dedicated events are documented but do not fire in current releases — they are registered here as forward-compatibility for when they start working.

   `padding` — character columns of left margin; `refreshInterval` — seconds
   between updates. It defaults to `30` here to keep the per-session cost low
   (the script re-runs on every refresh in every Claude session); lower it if
   you want a more live cost/context readout.

3. **Verify the scripts run:**

   ```bash
   echo '{}' | /path/to/terminal-config/claude/status_bar.sh
   echo '{"hook_event_name":"SessionStart","session_id":"test"}' \
       | /path/to/terminal-config/claude/task_hooks.sh
   ```

   The first command should print a status line with default/empty values. The second should
   exit silently (no sessions directory to prune yet). If `jq` is missing, both will error here
   rather than silently inside Claude Code.

4. **Restart Claude Code.** The status bar appears at the bottom of the terminal.

## How it works

- **Status line hook** — Claude Code pipes a JSON payload to `status_bar.sh`'s stdin on every
  tool call. The script parses it and prints up to two lines. Zero disk writes during rendering.
- **Git info** — a single `git rev-parse --show-toplevel --abbrev-ref HEAD` yields the repo name
  and branch with no working-tree scan, so cost is independent of repo size. Dirty/untracked
  counts are deliberately not shown (computing them requires a full `git status` walk on every
  refresh).
- **Task progress** — `task_hooks.sh` listens to `TaskCreated`, `TaskCompleted`, and `TaskUpdate`
  hook events and maintains a per-session state file at
  `~/.claude/status-bar/sessions/<session_id>.json`. The status bar reads that file directly;
  zero tokens consumed, zero disk writes during rendering.
- **Session lifecycle** — `task_hooks.sh` also handles `SessionStart` (prunes session files older
  than `STATUS_BAR_SESSION_TTL_DAYS` days) and `SessionEnd` (deletes the current session's file).
  Stale files from crashed or killed sessions are cleaned up automatically on the next session start.
- **EMA time estimation** — `task_hooks.sh` records completion timestamps in
  `~/.claude/status-bar/history.json` on each `TaskCompleted` event and uses an exponential moving
  average (α = 0.3) to predict time remaining. Estimates appear after 3+ task completions.
- **Bedrock support** — when cost data is unavailable (AWS Bedrock billing goes through AWS), the
  cost field is replaced with an approximate token count. If that's also unavailable, the field
  is hidden.

## Configuration

You can tune behaviour by exporting variables in your `~/.zshrc` or `~/.bashrc`:

```bash
# Maximum number of task completions to retain in history (default: 200).
export STATUS_BAR_MAX_HISTORY=200

# Days before an idle session file is pruned on next SessionStart (default: 1).
export STATUS_BAR_SESSION_TTL_DAYS=1
```

| Variable | Default | Description |
|----------|---------|-------------|
| `STATUS_BAR_MAX_HISTORY` | `200` | Completions kept in `history.json`; must be a positive integer |
| `STATUS_BAR_SESSION_TTL_DAYS` | `1` | Days before a session file is pruned as stale |
| `STATUS_BAR_DEBUG` | _(unset)_ | Set to `1` to dump the raw `statusLine` JSON payload to `/tmp/claude_status_debug.json` |

## Debugging

Set `STATUS_BAR_DEBUG=1` to dump the raw JSON payload Claude Code sends to `status_bar.sh`:

```bash
STATUS_BAR_DEBUG=1 echo '{}' | /path/to/terminal-config/claude/status_bar.sh
# raw payload written to /tmp/claude_status_debug.json
```

Inspect `/tmp/claude_status_debug.json` to see the exact field names your Claude Code version
sends, which lets you tune the jq paths if needed.

## Files written

| Path | Purpose |
|------|---------|
| `~/.claude/status-bar/history.json` | Global EMA completion history (written by `task_hooks.sh` on `TaskCompleted`) |
| `~/.claude/status-bar/sessions/<session_id>.json` | Per-session task state (written by `task_hooks.sh`, deleted on `SessionEnd`) |
| `/tmp/claude_status_debug.json` | Debug payload dump (only when `STATUS_BAR_DEBUG=1`) |
