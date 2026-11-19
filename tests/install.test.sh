#!/bin/bash
# End-to-end test of install.sh in a temp HOME with fake `claude` and `pi` commands.
# Usage: bash tests/install.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0

mkdir -p "$T/home" "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"
cp "$T/bin/claude" "$T/bin/pi"
chmod +x "$T/bin/claude" "$T/bin/pi"
JQ_DIR=$(dirname "$(command -v jq)")

out=$(env -u PI_CODING_AGENT_DIR -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
  HOME="$T/home" TERM_PROGRAM=ghostty PATH="$T/bin:$JQ_DIR:/usr/bin:/bin" \
  bash "$ROOT/install.sh" < /dev/null 2>&1)
status=$?

check() { # <name> <condition result 0|1>
  if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=$((FAILED + 1)); fi
}

[ "$status" = 0 ]; check "install.sh exits 0 (got $status)" $?
[ -x "$T/home/.claude/statusline.sh" ]; check "Claude Code statusline installed" $?
jq -e '.statusLine.command' "$T/home/.claude/settings.json" >/dev/null 2>&1; check "settings.json has statusLine" $?
[ -f "$T/home/.pi/agent/extensions/statusline.ts" ]; check "Pi extension installed" $?
[[ "$out" == *"Fonts: skipped: ghostty has the Nerd Font symbols built in"* ]]; check "font step runs" $?

if [ "$FAILED" -gt 0 ]; then
  printf '%s\n' "$out" | sed 's/^/    /'
  echo "$FAILED test(s) failed"
  exit 1
fi
echo "all tests passed"
