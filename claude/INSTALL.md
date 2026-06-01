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

1. **Make the script executable** (already done if you cloned this repo):

   ```bash
   chmod +x /path/to/terminal-config/claude/status_bar.sh
   ```

2. **Register it in `~/.claude/settings.json`**:

   Open `~/.claude/settings.json` and add the `statusLine` key. Replace
   `/path/to/terminal-config` with the actual path on your machine.

   If your `settings.json` already has other keys, merge the `statusLine` block
   in alongside them — do **not** replace the whole file:

   ```json
   {
     "hooks": { "...": "your existing hooks stay here" },
     "statusLine": {
       "type": "command",
       "command": "/path/to/terminal-config/claude/status_bar.sh",
       "padding": 2,
       "refreshInterval": 30
     }
   }
   ```

   If `settings.json` doesn't exist yet, create it with only the `statusLine`
   block (valid JSON requires the outer `{}`):

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/path/to/terminal-config/claude/status_bar.sh",
       "padding": 2,
       "refreshInterval": 30
     }
   }
   ```

   `padding` — character columns of left margin; `refreshInterval` — seconds
   between updates. It defaults to `30` here to keep the per-session cost low
   (the script re-runs on every refresh in every Claude session); lower it if
   you want a more live cost/context readout.

3. **Verify the script runs:**

   ```bash
   echo '{}' | /path/to/terminal-config/claude/status_bar.sh
   ```

   You should see a status line with default/empty values. If `jq` is missing, it will error here rather than silently inside Claude Code.

4. **Restart Claude Code.** The status bar appears at the bottom of the terminal.

## How it works

- **Status line hook** — Claude Code pipes a JSON payload to the script's stdin on every tool call. The script parses it and prints up to two lines.
- **Git info** — a single `git rev-parse --show-toplevel --abbrev-ref HEAD` yields the repo name and branch with no working-tree scan, so cost is independent of repo size. Dirty/untracked counts are deliberately not shown (computing them requires a full `git status` walk on every refresh).
- **Task progress** — reads `~/.claude/tasks/*.json` directly; zero tokens consumed.
- **EMA time estimation** — tracks completion timestamps in `~/.claude/status-bar/history.json` and uses an exponential moving average (α = 0.3) to predict time remaining. Estimates appear after 3+ task completions. `history.json` is rewritten **only when a task actually completes**, so an unchanged refresh performs no disk writes.
- **Bedrock support** — when cost data is unavailable (AWS Bedrock billing goes through AWS), the cost field is replaced with an approximate token count derived from the context window percentage. If that's also unavailable, the field is hidden.

## Configuration

You can tune the script's behaviour by exporting variables in your `~/.zshrc` or `~/.bashrc`:

```bash
# Maximum number of task completions to retain in history (default: 200).
# Older entries are pruned before the EMA is computed, so the estimate
# always reflects your most recent working pace.
export STATUS_BAR_MAX_HISTORY=200
```

| Variable | Default | Description |
|----------|---------|-------------|
| `STATUS_BAR_MAX_HISTORY` | `200` | Completions kept in `history.json`; must be a positive integer |
| `STATUS_BAR_DEBUG` | _(unset)_ | Set to `1` to dump the raw Claude Code JSON payload to `/tmp/claude_status_debug.json` |

## Debugging

Set `STATUS_BAR_DEBUG=1` to dump the raw JSON payload Claude Code sends:

```bash
STATUS_BAR_DEBUG=1 echo '{}' | /path/to/terminal-config/claude/status_bar.sh
# raw payload written to /tmp/claude_status_debug.json
```

Inspect `/tmp/claude_status_debug.json` to see the exact field names your Claude Code version sends, which lets you tune the jq paths at the top of `main()` if needed.

## Files written

| Path | Purpose |
|------|---------|
| `~/.claude/status-bar/history.json` | EMA completion history |
| `/tmp/claude_status_debug.json` | Debug payload dump (only when `STATUS_BAR_DEBUG=1`) |
