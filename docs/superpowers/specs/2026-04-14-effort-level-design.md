# Effort Level in Statusline

## Overview

Add the current effort level (min/low/medium/high/max) to the statusline, displayed next to the model name before the context bar. Only shown when the user has explicitly set it via `/effort` in the current session.

## Output Format

When effort is set:
```
[user@hostname] ~/Projects/git/llama.cpp | Opus 4.6 (max) [████░░░░░░] 42%
```

When effort is not set (no change from current behavior):
```
[user@hostname] ~/Projects/git/llama.cpp | Opus 4.6 [████░░░░░░] 42%
```

## Data Source

The effort level is **not** available in the statusline JSON input. Instead, it is extracted from the session transcript file:

- The transcript path is available in the JSON at `.transcript_path`
- Each `/effort` command produces a response entry with `<local-command-stdout>Set effort level to {level}...</local-command-stdout>`
- We match `"content":"<local-command-stdout>Set effort level to` to distinguish real effort responses (content is a JSON string) from tool calls that may reference the same text (content is a JSON array)
- We read the transcript backwards with `tac` and stop at the first match (`grep -m1`) for efficiency

## Implementation

All changes are in `statusline.sh`. No new files or dependencies.

### New extractions (after existing `jq` calls):

```bash
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // ""')

EFFORT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EFFORT=$(tac "$TRANSCRIPT" | grep -m1 '"content":"<local-command-stdout>Set effort level to' | grep -oP 'Set effort level to \K\w+')
fi
```

### Output change:

```bash
EFFORT_STR=""
if [ -n "$EFFORT" ]; then
  EFFORT_STR=" ($EFFORT)"
fi

echo -e "[...] $MODEL$EFFORT_STR ${COLOR}[${BAR}] ${PCT}%${RESET}"
```

## Approach

`tac | grep -m1` was chosen over:
- **Full `jq` scan** — reads entire transcript every call, slow on long sessions
- **Cached temp file** — unnecessary complexity; `tac | grep -m1` is already fast (reads backwards, stops at first match)
