#!/bin/bash
# Tests for the statusline.sh Nerd Font icons. Usage: bash tests/icons.test.sh (bash 4.2+)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

g() { printf "\\U$(printf '%08X' "0x$1")"; } # glyph for a hex codepoint

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A git repo so the branch and commit-age segments render
git -C "$T" init -q -b main
git -C "$T" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# A fake tmux on PATH so the tmux segment renders
mkdir -p "$T/bin"
printf '#!/bin/sh\necho work\n' > "$T/bin/tmux"
chmod +x "$T/bin/tmux"

JSON=$(printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"%s"},
  "context_window":{"used_percentage":42,"total_input_tokens":1200,"total_output_tokens":300,
    "total_cache_read_tokens":90,"total_cache_creation_tokens":10},
  "rate_limits":{"five_hour":{"used_percentage":12}},
  "cost":{"total_cost_usd":1.2,"total_duration_ms":600000}}' "$T")

render() { # <os-release ID line or "none">
  local release="$T/os-release"
  if [ "$1" = none ]; then rm -f "$release"; else printf '%s\n' "NAME=x" "$1" > "$release"; fi
  printf '%s' "$JSON" | env PATH="$T/bin:$PATH" TMUX=1 SSH_CONNECTION="1 2 3 4" AWS_PROFILE=prod \
    VIRTUAL_ENV=/x/venv STATUSLINE_UPDATE_CHECK=0 STATUSLINE_OS_RELEASE="$release" \
    bash "$ROOT/statusline.sh" 2>/dev/null
}

result() { # <name> <ok 0|1> <detail>
  if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; echo "    $3"; FAILED=$((FAILED + 1)); fi
}

starts_with() { # <name> <text> <prefix>
  [[ "$2" == "$3"* ]]
  result "$1" $? "expected [$(printf '%s' "$3" | cat -v)] at start of [$(printf '%s' "$2" | cat -v)]"
}

contains() { # <name> <text> <needle>
  [[ "$2" == *"$3"* ]]
  result "$1" $? "expected [$(printf '%s' "$3" | cat -v)] in [$(printf '%s' "$2" | cat -v)]"
}

OUT=$(render "ID=fedora")
L1=$(sed -n 1p <<< "$OUT"); L2=$(sed -n 2p <<< "$OUT"); L3=$(sed -n 3p <<< "$OUT")

# Line 1: host OS logo (nf-linux), branch, commit age
starts_with "fedora logo starts line 1"         "$L1" "$(g F30A) "
contains    "branch icon"                       "$L1" " $(g F062C) "
contains    "commit-age icon"                   "$L1" " $(g F0718) "

# Line 2: context, rate limits, cost, burn rate, model
starts_with "brain starts line 2"               "$L2" "$(g F09D1) "
contains    "rate-limit speedometer"            "$L2" " | $(g F04C5) "
contains    "cost icon"                         "$L2" " | $(g F01C1) 1.20"
contains    "burn-rate fire"                    "$L2" " | $(g F0238) "
contains    "model icon"                        "$L2" " | $(g F0674) Opus"

# Line 3: clock showing the current hour (outline), then the other segments
HOUR=$(( 10#$(date +%I) ))
starts_with "clock shows the current hour"      "$L3" "$(g "$(printf '%X' $((0xF144A + HOUR)))") "
contains    "duration timer"                    "$L3" " | $(g F051B) 10m"
contains    "cache snowflake"                   "$L3" " | $(g F0717) 90%"
contains    "tokens arrows"                     "$L3" " | $(g F04E2) 1.2K / 300"
contains    "AWS icon"                          "$L3" " | $(g F0E0F) prod"
contains    "python icon"                       "$L3" " | $(g F0320) venv"
contains    "tmux terminal icon"                "$L3" "$(g F489) work"
contains    "SSH icon"                          "$L3" "$(g F0318) SSH"

# Host logo per OS
starts_with "ubuntu logo"                       "$(render 'ID=ubuntu' | head -1)"              "$(g F31B) "
starts_with "quoted opensuse ID"                "$(render 'ID="opensuse-tumbleweed"' | head -1)" "$(g F314) "
starts_with "raspbian logo"                     "$(render 'ID=raspbian' | head -1)"            "$(g F315) "
starts_with "unknown distro falls back to tux"  "$(render 'ID=plan9' | head -1)"               "$(g F31A) "
if [[ "$OSTYPE" == darwin* ]]; then
  starts_with "macOS without os-release shows apple" "$(render none | head -1)" "$(g F302) "
fi

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED test(s) failed"
  exit 1
fi
echo "all tests passed"
