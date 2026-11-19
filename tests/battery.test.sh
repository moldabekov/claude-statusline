#!/bin/bash
# Tests for the statusline.sh battery segment (last item on line 3).
# A fake sysfs battery is served via STATUSLINE_POWER_SUPPLY. Usage: bash tests/battery.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
FAILED=0

# <capacity> <status> <expected color> <expected glyph> <name>
check() {
  local tmp line3 expected
  tmp=$(mktemp -d)
  mkdir -p "$tmp/BAT0"
  echo "$1" > "$tmp/BAT0/capacity"
  echo "$2" > "$tmp/BAT0/status"
  line3=$(printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"%s"}}' "$tmp" \
    | STATUSLINE_POWER_SUPPLY="$tmp" STATUSLINE_UPDATE_CHECK=0 bash "$ROOT/statusline.sh" 2>/dev/null | sed -n 3p)
  rm -rf "$tmp"
  expected=" | ${3}${4} ${1}%${RESET}"
  if [[ "$line3" == *"$expected" ]]; then
    echo "PASS $5"
  else
    echo "FAIL $5"
    echo "    expected line 3 to end with [$(printf '%s' "$expected" | cat -v)]"
    echo "    got [$(printf '%s' "$line3" | cat -v)]"
    FAILED=$((FAILED + 1))
  fi
}

check 75  Discharging    "$GREEN"  $'\U000F0081' "discharging 75% shows battery_80 in green"
check 100 Discharging    "$GREEN"  $'\U000F0079' "discharging 100% shows full battery in green"
check 35  Discharging    "$YELLOW" $'\U000F007D' "discharging 35% shows battery_40 in yellow"
check 3   Discharging    "$RED"    $'\U000F007A' "discharging 3% shows battery_10 in red"
check 15  Charging       "$RED"    $'\U000F0086' "charging 15% shows charging_20 in red"
check 100 Full           "$GREEN"  $'\U000F0085' "full while plugged shows charging_100"
check 35  "Not charging" "$YELLOW" $'\U000F0088' "plugged but not charging shows charging_40"
check 50  Unknown        "$GREEN"  $'\U000F007E' "unknown status counts as unplugged"

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED test(s) failed"
  exit 1
fi
echo "all tests passed"
