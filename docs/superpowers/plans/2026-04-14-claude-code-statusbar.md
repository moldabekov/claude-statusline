# Claude Code Statusbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a color-coded statusbar to Claude Code showing `[user@hostname] CWD | Model [████░░░░░░] NN%`

**Architecture:** A bash script at `~/.claude/statusline.sh` receives JSON session data on stdin, extracts fields via `jq`, and prints a formatted status line with ANSI-colored progress bar. Claude Code's `statusLine` setting in `~/.claude/settings.json` points to the script.

**Tech Stack:** Bash, jq

---

### File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `~/.claude/statusline.sh` | Create | Parse JSON, format and print status line |
| `~/.claude/settings.json` | Modify | Add `statusLine` configuration |

---

### Task 1: Create the statusline script

**Files:**
- Create: `~/.claude/statusline.sh`

- [ ] **Step 1: Create `~/.claude/statusline.sh`**

```bash
#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Tilde contraction
DIR="${DIR/#$HOME/\~}"

# Progress bar (10 chars)
FILLED=$((PCT / 10))
EMPTY=$((10 - FILLED))
BAR=""
for ((i=0; i<FILLED; i++)); do BAR+="█"; done
for ((i=0; i<EMPTY; i++)); do BAR+="░"; done

# Color by threshold
if [ "$PCT" -ge 80 ]; then
  COLOR='\033[31m'
elif [ "$PCT" -ge 60 ]; then
  COLOR='\033[33m'
else
  COLOR='\033[32m'
fi
RESET='\033[0m'

echo -e "[$USER@${HOSTNAME:-$(hostname)}] $DIR | $MODEL ${COLOR}[${BAR}] ${PCT}%${RESET}"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x ~/.claude/statusline.sh`

- [ ] **Step 3: Test with mock JSON (green — low usage)**

Run:
```bash
echo '{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/home/moldabekov/Projects/git/llama.cpp"},"context_window":{"used_percentage":42}}' | ~/.claude/statusline.sh
```

Expected output (with green ANSI coloring):
```
[moldabekov@<hostname>] ~/Projects/git/llama.cpp | Opus 4.6 [████░░░░░░] 42%
```

- [ ] **Step 4: Test with mock JSON (yellow — medium usage)**

Run:
```bash
echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"/home/moldabekov"},"context_window":{"used_percentage":65.3}}' | ~/.claude/statusline.sh
```

Expected output (with yellow ANSI coloring):
```
[moldabekov@<hostname>] ~ | Sonnet 4.6 [██████░░░░] 65%
```

- [ ] **Step 5: Test with mock JSON (red — high usage)**

Run:
```bash
echo '{"model":{"display_name":"Haiku 4.5"},"workspace":{"current_dir":"/home/moldabekov/Projects"},"context_window":{"used_percentage":91.7}}' | ~/.claude/statusline.sh
```

Expected output (with red ANSI coloring):
```
[moldabekov@<hostname>] ~/Projects | Haiku 4.5 [█████████░] 91%
```

- [ ] **Step 6: Test edge cases (0% and 100%)**

Run:
```bash
echo '{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":0}}' | ~/.claude/statusline.sh
echo '{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":100}}' | ~/.claude/statusline.sh
```

Expected:
```
[moldabekov@<hostname>] /tmp | Opus 4.6 [░░░░░░░░░░] 0%
[moldabekov@<hostname>] /tmp | Opus 4.6 [██████████] 100%
```

---

### Task 2: Configure Claude Code settings

**Files:**
- Modify: `~/.claude/settings.json`

- [ ] **Step 1: Add statusLine to settings.json**

Add the `statusLine` key to the existing settings object. The file currently contains only `enabledPlugins`. After the edit:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  },
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "code-review@claude-plugins-official": true,
    "code-simplifier@claude-plugins-official": true,
    "github@claude-plugins-official": true,
    "playwright@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "ralph-loop@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "huggingface-skills@claude-plugins-official": true,
    "firecrawl@claude-plugins-official": true
  }
}
```

- [ ] **Step 2: Verify the statusbar works**

Restart Claude Code (or start a new session). The statusbar should appear at the bottom showing:
```
[moldabekov@<hostname>] ~/... | <model> [██░░░░░░░░] NN%
```
