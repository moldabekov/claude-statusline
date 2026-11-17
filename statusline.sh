#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // ""')
WORKTREE=$(echo "$input" | jq -r '.workspace.git_worktree // ""')
RATE_5H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // ""')
RATE_5H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // ""')
RATE_7D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // ""')
RATE_7D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // ""')
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
  # Keyed by HEAD commit SHA so tag-triggered runs are matched (head_branch=tag_name
  # would otherwise be excluded by --branch) and the cache auto-invalidates on new commits.
  if command -v gh &>/dev/null; then
    head_sha=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
    if [ -n "$head_sha" ]; then
      ci_key=$(echo "${DIR}${head_sha}" | md5sum | cut -c1-12)
      ci_cache="/tmp/claude-statusline-ci-${ci_key}"
      now=$(date +%s)
      mtime=$(stat -c %Y "$ci_cache" 2>/dev/null || echo 0)
      if [ "$((now - mtime))" -gt 60 ]; then
        ( cd "$DIR" && gh run list --commit "$head_sha" --limit 1 --json status,conclusion,updatedAt 2>/dev/null \
            > "${ci_cache}.tmp" && mv "${ci_cache}.tmp" "$ci_cache" ) &>/dev/null &
      fi
      if [ -f "$ci_cache" ]; then
        ci_count=$(jq 'length' "$ci_cache" 2>/dev/null || echo 0)
        if [ "$ci_count" = "0" ]; then
          CI_STR=" | ○"
        else
          ci_status=$(jq -r '.[0].status // ""' "$ci_cache" 2>/dev/null)
          ci_conc=$(jq -r '.[0].conclusion // ""' "$ci_cache" 2>/dev/null)
          ci_time=$(jq -r '.[0].updatedAt // ""' "$ci_cache" 2>/dev/null)
          ci_age=""
          if [ -n "$ci_time" ]; then
            ci_epoch=$(date -d "$ci_time" +%s 2>/dev/null)
            if [ -n "$ci_epoch" ]; then
              ci_delta=$((now - ci_epoch))
              if [ "$ci_delta" -lt 60 ]; then ci_age="${ci_delta}s"
              elif [ "$ci_delta" -lt 3600 ]; then ci_age="$((ci_delta / 60))m"
              elif [ "$ci_delta" -lt 86400 ]; then ci_age="$((ci_delta / 3600))h"
              else ci_age="$((ci_delta / 86400))d"
              fi
            fi
          fi
          ci_color=""
          ci_icon=""
          case "$ci_conc" in
            success) ci_color="32"; ci_icon="✓" ;;
            failure|cancelled|timed_out|startup_failure) ci_color="31"; ci_icon="✗" ;;
            *)
              if [ "$ci_status" = "in_progress" ] || [ "$ci_status" = "queued" ] || [ "$ci_status" = "waiting" ]; then
                ci_color="33"; ci_icon="⋯"
              fi
              ;;
          esac
          if [ -n "$ci_icon" ]; then
            CI_STR=" | \033[${ci_color}m${ci_icon}"
            if [ -n "$ci_age" ]; then
              CI_STR="${CI_STR} ${ci_age}"
            fi
            CI_STR="${CI_STR}\033[0m"
          fi
        fi
      fi
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

# Format reset countdown from epoch timestamp
format_reset() {
  local epoch=$1
  if [ -z "$epoch" ] || [ "$epoch" = "null" ]; then return; fi
  local remain=$(( epoch - $(date +%s) ))
  if [ "$remain" -le 0 ]; then echo "now"; return; fi
  if [ "$remain" -ge 86400 ]; then
    echo "$(date -d "@$epoch" +%b%d)"
  elif [ "$remain" -ge 3600 ]; then
    echo "$((remain/3600))h$((remain%3600/60))m"
  elif [ "$remain" -ge 60 ]; then
    echo "$((remain/60))m"
  else
    echo "${remain}s"
  fi
}

# Rate limits (colorized independently, with reset countdown)
# Render one rate-limit window: format_limit <label> <used_pct> <resets_at>
format_limit() {
  local label=$1 pct=$2 reset_at=$3
  if [ -z "$pct" ] || [ "$pct" = "null" ]; then return; fi
  local p=${pct%.*} c reset_str
  if [ "$p" -ge 80 ]; then c='\033[31m'; elif [ "$p" -ge 60 ]; then c='\033[33m'; else c='\033[32m'; fi
  reset_str=$(format_reset "$reset_at")
  if [ -n "$reset_str" ]; then
    echo "${c}${label}: ${p}% ↻ ${reset_str}${RESET}"
  else
    echo "${c}${label}: ${p}%${RESET}"
  fi
}

# Each window is optional — show whichever ones are present
LIMITS_STR=""
R5_STR=$(format_limit "5h" "$RATE_5H" "$RATE_5H_RESET")
R7_STR=$(format_limit "7d" "$RATE_7D" "$RATE_7D_RESET")
if [ -n "$R5_STR" ] && [ -n "$R7_STR" ]; then
  LIMITS_STR=" | ⏱ ${R5_STR} / ${R7_STR}"
elif [ -n "$R5_STR" ] || [ -n "$R7_STR" ]; then
  LIMITS_STR=" | ⏱ ${R5_STR}${R7_STR}"
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
  BRANCH_STR=" ⎇ ${CYAN}${BRANCH}${RESET}"
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

# Battery (Linux sysfs, macOS pmset — hidden on machines without one)
BATTERY_STR=""
for bat in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
  if [ -r "$bat/capacity" ]; then
    BATTERY_STR=" | 🔋 $(cat "$bat/capacity")%"
    break
  fi
done
if [ -z "$BATTERY_STR" ] && [[ "$OSTYPE" == darwin* ]]; then
  # " -InternalBattery-0 (id=…)	85%; charging; 1:02 remaining present: true"
  bat_pct=$(/usr/bin/pmset -g batt 2>/dev/null | awk '/InternalBattery/ { if (match($0, /[0-9]+%/)) print substr($0, RSTART, RLENGTH - 1); exit }')
  [ -n "$bat_pct" ] && BATTERY_STR=" | 🔋 ${bat_pct}%"
fi

# Host load — readers print "<load1> <cores> <mem_total_kb> <mem_used_kb> <swap_total_kb> <swap_used_kb>"
# Linux: used RAM = MemTotal − MemAvailable (matches `free`)
read_host_linux() {
  [ -r /proc/loadavg ] && [ -r /proc/meminfo ] || return
  local load1 cores
  read -r load1 _ < /proc/loadavg
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  awk -v load="$load1" -v cores="$cores" '
    /^MemTotal:/                   { total = $2 }
    /^MemAvailable:/               { avail = $2; has_avail = 1 }
    /^(MemFree|Buffers|Cached):/   { legacy += $2 }
    /^SwapTotal:/                  { swap_total = $2 }
    /^SwapFree:/                   { swap_free = $2 }
    END {
      if (!has_avail) avail = legacy   # kernels older than 3.14
      if (total > 0) printf "%s %d %d %d %d %d\n", load, cores, total, total - avail, swap_total, swap_total - swap_free
    }' /proc/meminfo
}

# macOS: used RAM = app (anonymous − purgeable) + wired + compressed (matches Activity Monitor)
read_host_darwin() {
  { /usr/sbin/sysctl vm.loadavg hw.ncpu hw.memsize vm.swapusage; /usr/bin/vm_stat; } 2>/dev/null | awk '
    function to_kb(v,   n, u) {
      n = v + 0; u = substr(v, length(v))
      if (u == "G") return n * 1048576
      if (u == "K") return n
      return n * 1024   # sysctl reports swap in M
    }
    { val = $NF; sub(/\.$/, "", val) }
    $1 == "vm.loadavg:"   { load = $3 }
    $1 == "hw.ncpu:"      { cores = $2 }
    $1 == "hw.memsize:"   { mem_total = $2 / 1024 }
    $1 == "vm.swapusage:" {
      for (i = 2; i < NF; i++) {
        if ($i == "total") swap_total = to_kb($(i + 2))
        if ($i == "used") swap_used = to_kb($(i + 2))
      }
    }
    /page size of/                   { page_kb = $(NF - 1) / 1024 }
    /^Pages wired down:/             { wired = val }
    /^Pages purgeable:/              { purgeable = val }
    /^Pages active:/                 { active = val }
    /^Anonymous pages:/              { anon = val; has_anon = 1 }
    /^Pages occupied by compressor:/ { compressed = val }
    END {
      if (!page_kb || !mem_total) exit
      app = has_anon ? anon - purgeable : active
      printf "%s %d %d %d %d %d\n", load, cores, mem_total, (app + wired + compressed) * page_kb, swap_total, swap_used
    }'
}

# Reader line → "<load> <cpu_pct> <mem_used/totalG> <mem_pct> [<swap_used/totalG> <swap_pct>]"
# cpu_pct is load per core; swap fields are omitted when there is no swap
format_host() {
  awk 'function gb(kb,   g) { g = kb / 1048576; return sprintf(g >= 10 ? "%.0f" : "%.1f", g) }
    NF == 6 {
      cores = $2 > 0 ? $2 : 1
      printf "%.2f %d %.1f/%sG %d", $1, $1 * 100 / cores, $4 / 1048576, gb($3), ($3 > 0 ? $4 * 100 / $3 : 0)
      if ($5 > 0) printf " %.1f/%sG %d", $6 / 1048576, gb($5), $6 * 100 / $5
      printf "\n"
    }'
}

# Green <60%, yellow 60–79%, red ≥80%
threshold_color() {
  if [ "$1" -ge 80 ]; then echo '\033[31m'; elif [ "$1" -ge 60 ]; then echo '\033[33m'; else echo '\033[32m'; fi
}

# Nerd Font icons: nf-md-cpu_64_bit (U+F0EE0), nf-md-memory (U+F035B), nf-md-sync (U+F04E6)
ICON_CPU="󰻠"
ICON_RAM="󰍛"
ICON_SWAP="󰓦"

HOST_STR=""
case "$OSTYPE" in
  linux*)  HOST_RAW=$(read_host_linux) ;;
  darwin*) HOST_RAW=$(read_host_darwin) ;;
  *)       HOST_RAW="" ;;
esac
if [ -n "$HOST_RAW" ]; then
  read -r H_LOAD H_CPU_PCT H_MEM H_MEM_PCT H_SWAP H_SWAP_PCT <<< "$(format_host <<< "$HOST_RAW")"
  if [ -n "$H_MEM_PCT" ]; then
    HOST_STR=" | $(threshold_color "$H_CPU_PCT")${ICON_CPU} ${H_LOAD}${RESET} | $(threshold_color "$H_MEM_PCT")${ICON_RAM} ${H_MEM}${RESET}"
    [ -n "$H_SWAP_PCT" ] && HOST_STR+=" | $(threshold_color "$H_SWAP_PCT")${ICON_SWAP} ${H_SWAP}${RESET}"
  fi
fi

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
echo -e "${TIME_STR}${DUR_STR}${HOST_STR}${CACHE_STR}${TOKENS_STR}${ENV_STR}${TMUX_STR}${SSH_STR}${BATTERY_STR}"
