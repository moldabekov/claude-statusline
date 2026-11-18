#!/bin/bash
# Run all tests: bash (statusline.sh) and, when Pi is installed, TypeScript (statusline.ts).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0

bash "$ROOT/tests/update-check.test.sh" || status=1

# statusline.ts imports @earendil-works/pi-tui; borrow it from the installed Pi
pi_tui="${PI_TUI_DIR:-}"
if [ -z "$pi_tui" ] && command -v npm &>/dev/null; then
  pi_tui="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui"
fi

if [ -n "$pi_tui" ] && [ -d "$pi_tui" ] && command -v node &>/dev/null; then
  mkdir -p "$ROOT/node_modules/@earendil-works"
  ln -sfn "$pi_tui" "$ROOT/node_modules/@earendil-works/pi-tui"
  node --test "$ROOT/tests/update-check.test.ts" || status=1
else
  echo "SKIP ts tests (pi-tui not found; set PI_TUI_DIR)"
fi

exit "$status"
