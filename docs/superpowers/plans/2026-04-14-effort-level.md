# Effort Level in Statusline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the current effort level next to the model name in the statusline, parsed from the session transcript.

**Architecture:** Read `transcript_path` from the statusline JSON, search backwards for the last `/effort` command with `tac | grep -m1`, conditionally append the level to the output.

**Tech Stack:** Bash, jq, tac, grep (PCRE)

---

### Task 1: Add effort level to statusline

**Files:**
- Modify: `statusline.sh:1-31`

- [ ] **Step 1: Remove the debug dump**

Remove lines 4-5 (the temporary debug code):

```bash
# Debug: dump raw JSON to file
echo "$input" > /tmp/statusline-debug.json
```

- [ ] **Step 2: Add transcript path extraction**

After the existing `jq` extractions (after line 9 in the current file, which will be line 7 after removing debug), add:

```bash
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // ""')
```

- [ ] **Step 3: Add effort level parsing**

After the transcript extraction, add:

```bash
# Effort level from transcript (only shown when explicitly set)
EFFORT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EFFORT=$(tac "$TRANSCRIPT" | grep -m1 'command-name./effort' | grep -oP '<command-args>\K[^<]+')
fi
EFFORT_STR=""
if [ -n "$EFFORT" ]; then
  EFFORT_STR=" ($EFFORT)"
fi
```

- [ ] **Step 4: Update the output line**

Change the final `echo` from:

```bash
echo -e "[$USER@${HOSTNAME:-$(hostname)}] $DIR | $MODEL ${COLOR}[${BAR}] ${PCT}%${RESET}"
```

to:

```bash
echo -e "[$USER@${HOSTNAME:-$(hostname)}] $DIR | $MODEL$EFFORT_STR ${COLOR}[${BAR}] ${PCT}%${RESET}"
```

- [ ] **Step 5: Verify manually**

Test with a mock JSON + transcript:

```bash
# Create mock transcript with an effort entry
echo '{"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n            <command-message>effort</command-message>\n            <command-args>max</command-args>"}}' > /tmp/test-transcript.jsonl

# Run statusline with mock input
echo '{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/home/user/project"},"context_window":{"used_percentage":42},"transcript_path":"/tmp/test-transcript.jsonl"}' | bash statusline.sh
```

Expected output contains: `Opus 4.6 (max)`

Test without effort in transcript:

```bash
echo '{"type":"user","message":{"role":"user","content":"hello"}}' > /tmp/test-transcript-noeffort.jsonl

echo '{"model":{"display_name":"Opus 4.6"},"workspace":{"current_dir":"/home/user/project"},"context_window":{"used_percentage":42},"transcript_path":"/tmp/test-transcript-noeffort.jsonl"}' | bash statusline.sh
```

Expected output: `Opus 4.6` with no parenthetical.

- [ ] **Step 6: Install and verify live**

```bash
cp statusline.sh ~/.claude/statusline.sh
```

Confirm the statusline updates in Claude Code after the next refresh.

- [ ] **Step 7: Commit**

```bash
git add statusline.sh
git commit -m "feat: show effort level next to model name in statusline"
```

### Task 2: Clean up debug file

- [ ] **Step 1: Remove debug artifact**

```bash
rm -f /tmp/statusline-debug.json
```
