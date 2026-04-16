#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // ""')
WORKTREE=$(echo "$input" | jq -r '.workspace.git_worktree // ""')
RATE_5H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // ""')
RATE_7D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // ""')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // ""')

# Effort level from transcript (only shown when explicitly set)
EFFORT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EFFORT=$(tac "$TRANSCRIPT" | grep -m1 '"content":"<local-command-stdout>Set effort level to' | grep -oP 'Set effort level to \K\w+')
fi
EFFORT_STR=""
if [ -n "$EFFORT" ]; then
  EFFORT_STR=" ($EFFORT)"
fi

# Git branch
BRANCH=""
if [ -d "$DIR" ]; then
  BRANCH=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || git -C "$DIR" rev-parse --short HEAD 2>/dev/null || true)
fi

# Worktree segment
WORKTREE_STR=""
if [ -n "$WORKTREE" ]; then
  WORKTREE_STR=" | $WORKTREE"
fi

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

# Rate limits (colorized independently)
LIMITS_STR=""
if [ -n "$RATE_5H" ] && [ -n "$RATE_7D" ]; then
  R5=${RATE_5H%.*}
  R7=${RATE_7D%.*}
  if [ "$R5" -ge 80 ]; then C5='\033[31m'; elif [ "$R5" -ge 60 ]; then C5='\033[33m'; else C5='\033[32m'; fi
  if [ "$R7" -ge 80 ]; then C7='\033[31m'; elif [ "$R7" -ge 60 ]; then C7='\033[33m'; else C7='\033[32m'; fi
  LIMITS_STR=" | ⏱  ${C5}5h: ${R5}%${RESET} / ${C7}7d: ${R7}%${RESET}"
fi

# Cost
COST_STR=""
if [ -n "$COST" ] && [ "$COST" != "0" ]; then
  COST_FMT=$(printf '%.2f' "$COST")
  COST_STR=" | \$${COST_FMT}"
fi

BLUE='\033[34m'
YELLOW='\033[33m'
CYAN='\033[36m'

BRANCH_STR=""
if [ -n "$BRANCH" ]; then
  BRANCH_STR=" ⎇  ${CYAN}${BRANCH}${RESET}"
fi

echo -e "🖥  ${BLUE}[$USER@${HOSTNAME:-$(hostname)}]${RESET} ▸ ${YELLOW}$DIR${RESET}${BRANCH_STR}${WORKTREE_STR}"
echo -e "⚡ ${COLOR}[${BAR}] ${PCT}%${RESET}${LIMITS_STR}${COST_STR} | ✦ $MODEL$EFFORT_STR"
