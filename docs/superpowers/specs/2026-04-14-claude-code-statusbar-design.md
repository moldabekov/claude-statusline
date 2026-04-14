# Claude Code Statusbar Design

## Overview

Add a statusbar to Claude Code showing hostname, current working directory, model name, and context usage with a color-coded progress bar.

## Output Format

```
[user@hostname] ~/Projects/git/llama.cpp | Opus 4.6 [████░░░░░░] 42%
```

## Segments

| # | Segment | Source | Example |
|---|---------|--------|---------|
| 1 | `[user@hostname]` | `$USER`, `$HOSTNAME` env vars | `[moldabekov@devbox]` |
| 2 | CWD | JSON `.workspace.current_dir`, `$HOME` replaced with `~` | `~/Projects/git/llama.cpp` |
| 3 | Model name | JSON `.model.display_name` | `Opus 4.6` |
| 4 | Progress bar | 10-char bar from JSON `.context_window.used_percentage` | `[████░░░░░░]` |
| 5 | Percentage | Integer from `.context_window.used_percentage` | `42%` |

Segments separated by ` | `. The bar and percentage are colored together.

## Color Thresholds

Applied to the progress bar and percentage text via ANSI escape codes:

| Range | Color | ANSI Code |
|-------|-------|-----------|
| 0-59% | Green | `\033[32m` |
| 60-79% | Yellow | `\033[33m` |
| 80-100% | Red | `\033[31m` |

Color resets after the percentage with `\033[0m`.

## Progress Bar Characters

- Filled: `█` (U+2588)
- Empty: `░` (U+2591)
- Total width: 10 characters
- Enclosed in `[]`

## Implementation

### Files

1. **`~/.claude/statusline.sh`** — Bash script, reads JSON from stdin via `jq`
2. **`~/.claude/settings.json`** — Add `statusLine` configuration

### Script Logic

1. Read JSON from stdin into a variable
2. Extract `.model.display_name`, `.workspace.current_dir`, `.context_window.used_percentage` via `jq`
3. Replace `$HOME` prefix with `~` in CWD
4. Compute filled/empty bar character counts from percentage (integer division by 10)
5. Select ANSI color based on percentage threshold
6. Print formatted output line

### Settings Configuration

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

No `refreshInterval` needed — Claude Code fires the script on events (model change, context update, cost change).

### Dependencies

- `jq` — for JSON parsing (standard on systems running Claude Code)
- `bash` — script interpreter

## Approach

Pure bash + jq. Chosen over inline jq (unmaintainable with color logic) and Python (unnecessary startup overhead).
