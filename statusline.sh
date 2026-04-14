#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // ""')

# Effort level from transcript (only shown when explicitly set)
EFFORT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EFFORT=$(tac "$TRANSCRIPT" | grep -m1 '"content":"<local-command-stdout>Set effort level to' | grep -oP 'Set effort level to \K\w+')
fi
EFFORT_STR=""
if [ -n "$EFFORT" ]; then
  EFFORT_STR=" ($EFFORT)"
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

echo -e "[$USER@${HOSTNAME:-$(hostname)}] $DIR | $MODEL$EFFORT_STR ${COLOR}[${BAR}] ${PCT}%${RESET}"
