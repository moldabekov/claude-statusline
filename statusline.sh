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
TOKENS_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOKENS_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
CACHE_READ=$(echo "$input" | jq -r '.context_window.total_cache_read_tokens // 0')
CACHE_CREATE=$(echo "$input" | jq -r '.context_window.total_cache_creation_tokens // 0')
DUR_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Effort level from transcript (only shown when explicitly set)
EFFORT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EFFORT=$(tac "$TRANSCRIPT" | grep -m1 '"content":"<local-command-stdout>Set effort level to' | grep -oP 'Set effort level to \K\w+')
fi
EFFORT_STR=""
if [ -n "$EFFORT" ]; then
  EFFORT_STR=" ($EFFORT)"
fi

# Git branch + extras
BRANCH=""
GIT_DIRTY_STR=""
GIT_AHEAD_STR=""
GIT_STASH_STR=""
CI_STR=""
COMMIT_AGE_STR=""
if [ -d "$DIR" ] && git -C "$DIR" rev-parse --git-dir &>/dev/null; then
  BRANCH=$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || git -C "$DIR" rev-parse --short HEAD 2>/dev/null || true)

  # Last commit age
  commit_epoch=$(git -C "$DIR" log -1 --format=%ct 2>/dev/null)
  if [ -n "$commit_epoch" ]; then
    age_s=$(( $(date +%s) - commit_epoch ))
    if [ "$age_s" -ge 86400 ]; then
      age="$((age_s / 86400))d"
    elif [ "$age_s" -ge 3600 ]; then
      age="$((age_s / 3600))h"
    elif [ "$age_s" -ge 60 ]; then
      age="$((age_s / 60))m"
    else
      age="${age_s}s"
    fi
    COMMIT_AGE_STR=" ⏳ ${age}"
  fi

  # Dirty state (modified / staged / untracked)
  porc=$(git -C "$DIR" status --porcelain 2>/dev/null)
  if [ -n "$porc" ]; then
    mod=$(echo "$porc" | grep -c '^.M')
    stg=$(echo "$porc" | grep -c '^[MADRC]')
    unt=$(echo "$porc" | grep -c '^??')
    dparts=""
    [ "$mod" -gt 0 ] && dparts="${dparts} ●${mod}"
    [ "$stg" -gt 0 ] && dparts="${dparts} +${stg}"
    [ "$unt" -gt 0 ] && dparts="${dparts} ?${unt}"
    [ -n "$dparts" ] && GIT_DIRTY_STR=" |${dparts}"
  fi

  # Ahead / behind upstream
  ab=$(git -C "$DIR" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
  if [ -n "$ab" ]; then
    ah=$(echo "$ab" | awk '{print $1}')
    bh=$(echo "$ab" | awk '{print $2}')
    aparts=""
    [ "${ah:-0}" -gt 0 ] && aparts="${aparts} ↑${ah}"
    [ "${bh:-0}" -gt 0 ] && aparts="${aparts} ↓${bh}"
    [ -n "$aparts" ] && GIT_AHEAD_STR=" |${aparts}"
  fi

  # Stash count
  stash=$(git -C "$DIR" stash list 2>/dev/null | wc -l)
  if [ "$stash" -gt 0 ]; then
    GIT_STASH_STR=" | ≡${stash}"
  fi

  # CI status via gh (cached 60s, populated in background)
  if [ -n "$BRANCH" ] && command -v gh &>/dev/null; then
    ci_key=$(echo "${DIR}${BRANCH}" | md5sum | cut -c1-12)
    ci_cache="/tmp/claude-statusline-ci-${ci_key}"
    now=$(date +%s)
    mtime=$(stat -c %Y "$ci_cache" 2>/dev/null || echo 0)
    if [ "$((now - mtime))" -gt 60 ]; then
      ( cd "$DIR" && gh run list --branch "$BRANCH" --limit 1 --json status,conclusion 2>/dev/null \
          > "${ci_cache}.tmp" && mv "${ci_cache}.tmp" "$ci_cache" ) &>/dev/null &
    fi
    if [ -f "$ci_cache" ]; then
      ci_status=$(jq -r '.[0].status // ""' "$ci_cache" 2>/dev/null)
      ci_conc=$(jq -r '.[0].conclusion // ""' "$ci_cache" 2>/dev/null)
      case "$ci_conc" in
        success) CI_STR=" | \033[32m✓\033[0m" ;;
        failure|cancelled|timed_out|startup_failure) CI_STR=" | \033[31m✗\033[0m" ;;
        *)
          if [ "$ci_status" = "in_progress" ] || [ "$ci_status" = "queued" ] || [ "$ci_status" = "waiting" ]; then
            CI_STR=" | \033[33m⋯\033[0m"
          fi
          ;;
      esac
    fi
  fi
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

# Burn rate (tokens per minute) — green <3K, yellow 3-10K, red >10K
BURN_STR=""
DUR_S=$((DUR_MS / 1000))
if [ "$DUR_S" -gt 0 ] && [ "$((TOKENS_IN + TOKENS_OUT))" -gt 0 ]; then
  rate_tpm=$(awk "BEGIN {printf \"%.0f\", ($TOKENS_IN + $TOKENS_OUT) / ($DUR_S/60)}")
  if [ "$rate_tpm" -ge 1000000 ]; then
    rate_fmt=$(awk "BEGIN {printf \"%.1fM/m\", $rate_tpm/1000000}")
  elif [ "$rate_tpm" -ge 1000 ]; then
    rate_fmt=$(awk "BEGIN {printf \"%.1fK/m\", $rate_tpm/1000}")
  else
    rate_fmt="${rate_tpm}/m"
  fi
  if [ "$rate_tpm" -ge 10000 ]; then
    BURN_COLOR='\033[31m'
  elif [ "$rate_tpm" -ge 3000 ]; then
    BURN_COLOR='\033[33m'
  else
    BURN_COLOR='\033[32m'
  fi
  BURN_STR=" | 🔥 ${BURN_COLOR}${rate_fmt}\033[0m"
fi

BLUE='\033[34m'
YELLOW='\033[33m'
CYAN='\033[36m'

BRANCH_STR=""
if [ -n "$BRANCH" ]; then
  BRANCH_STR=" ⎇  ${CYAN}${BRANCH}${RESET}"
fi

# ---------- Line 3 data ----------
format_n() {
  local v=$1
  if [ "$v" -ge 1000000 ]; then
    awk "BEGIN {printf \"%.1fM\", $v/1000000}"
  elif [ "$v" -ge 1000 ]; then
    awk "BEGIN {printf \"%.1fK\", $v/1000}"
  else
    echo "$v"
  fi
}

TIME_STR="🕐 $(date +%H:%M)"

# Battery (Linux — skip if missing)
BATTERY_STR=""
for bat in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
  if [ -r "$bat/capacity" ]; then
    BATTERY_STR=" | 🔋 $(cat "$bat/capacity")%"
    break
  fi
done

# Tokens in/out
TOKENS_STR=""
if [ "$TOKENS_IN" -gt 0 ] || [ "$TOKENS_OUT" -gt 0 ]; then
  TOKENS_STR=" | ⇅ $(format_n "$TOKENS_IN") / $(format_n "$TOKENS_OUT")"
fi

# Cache hit ratio
CACHE_STR=""
if [ "$((CACHE_READ + CACHE_CREATE))" -gt 0 ]; then
  ratio=$(awk "BEGIN {printf \"%.0f\", $CACHE_READ*100/($CACHE_READ+$CACHE_CREATE)}")
  CACHE_STR=" | ❄ ${ratio}%"
fi

# Session duration
DUR_STR=""
if [ "$DUR_S" -gt 0 ]; then
  if [ "$DUR_S" -ge 3600 ]; then
    DUR_STR=" | ⧗ $((DUR_S/3600))h$((DUR_S%3600/60))m"
  elif [ "$DUR_S" -ge 60 ]; then
    DUR_STR=" | ⧗ $((DUR_S/60))m"
  else
    DUR_STR=" | ⧗ ${DUR_S}s"
  fi
fi

# Env metrics (conditional)
ENV_STR=""
[ -n "$AWS_PROFILE" ] && ENV_STR+=" | ☁ $AWS_PROFILE"
if [ -n "$VIRTUAL_ENV" ]; then
  ENV_STR+=" | 🐍 $(basename "$VIRTUAL_ENV")"
elif [ -f "$DIR/.python-version" ]; then
  ENV_STR+=" | 🐍 $(cat "$DIR/.python-version")"
fi

# Tmux session
TMUX_STR=""
if [ -n "$TMUX" ]; then
  tmux_session=$(tmux display-message -p '#S' 2>/dev/null)
  [ -n "$tmux_session" ] && TMUX_STR=" | ${CYAN}▦ ${tmux_session}${RESET}"
fi

# SSH session indicator
SSH_STR=""
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
  SSH_STR=" | ${CYAN}⇋ SSH${RESET}"
fi

echo -e "💻 ${BLUE}[${RESET}${CYAN}$USER${RESET}${BLUE}@${HOSTNAME:-$(hostname)}]${RESET} ▸ ${YELLOW}$DIR${RESET}${BRANCH_STR}${COMMIT_AGE_STR}${CI_STR}${GIT_DIRTY_STR}${GIT_AHEAD_STR}${GIT_STASH_STR}${WORKTREE_STR}"
echo -e "⚡ ${COLOR}[${BAR}] ${PCT}%${RESET}${LIMITS_STR}${COST_STR}${BURN_STR} | ✦ $MODEL$EFFORT_STR"
echo -e "${TIME_STR}${BATTERY_STR}${DUR_STR}${CACHE_STR}${TOKENS_STR}${ENV_STR}${TMUX_STR}${SSH_STR}"
