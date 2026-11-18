#!/bin/bash
# Offline tests for the statusline.sh update notice (line 4).
# Each test runs a copy of statusline.sh against a local file:// fixture of the
# GitHub tree API, with its own cache dir. Usage: bash tests/update-check.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STALE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TS_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
INTERVAL=21600
NOTICE=$'\033[1;38;5;16;48;5;208m 󰚰 Update available — statusline.sh changed on master · git pull && ./install.sh \033[0m'

FAILED=0
ERRORS=""

setup() {
  T=$(mktemp -d)
  cp "$ROOT/statusline.sh" "$T/statusline.sh"
  CACHE="$T/cache"
  export STATUSLINE_UPDATE_CACHE="$CACHE"
  export STATUSLINE_UPDATE_URL="file://$T/tree.json"
  unset STATUSLINE_UPDATE_CHECK
  OWN_SHA=$(git hash-object --no-filters "$T/statusline.sh")
}

teardown() { rm -rf "$T"; }

fail() { ERRORS+="    $1"$'\n'; return 1; }

assert_eq() { # <what> <expected> <actual>
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
}

# Fixture tree; pass an empty sha to leave statusline.sh out
tree_with() { # <statusline.sh sha>
  local entries="{\"path\":\"README.md\",\"type\":\"blob\",\"sha\":\"$TS_SHA\"},{\"path\":\"statusline.ts\",\"type\":\"blob\",\"sha\":\"$TS_SHA\"}"
  [ -n "$1" ] && entries+=",{\"path\":\"statusline.sh\",\"type\":\"blob\",\"sha\":\"$1\"}"
  printf '{"sha":"x","tree":[%s],"truncated":false}' "$entries" > "$T/tree.json"
}

seed_cache() { # <statusline.sh sha> <stamp>
  mkdir -p "$CACHE"
  printf '%s statusline.sh\n%s statusline.ts\n' "$1" "$TS_SHA" > "$CACHE/update-master"
  printf '%s\n' "$2" > "$CACHE/update-checked"
}

render() {
  printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":1}}' "$T" \
    | bash "$T/statusline.sh" 2>"$T/stderr"
}

line_count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

# Wait (max 5s) until update-master differs from <old content>
wait_for_master_change() { # <old content>
  local i
  for i in $(seq 1 50); do
    [ "$(cat "$CACHE/update-master" 2>/dev/null)" != "$1" ] && return 0
    sleep 0.1
  done
  fail "update-master never changed"
}

# ---------- tests ----------

test_stale_shows_notice() {
  tree_with "$STALE_SHA"
  render >/dev/null
  wait_for_master_change "" || return 1
  local out; out=$(render)
  assert_eq "line count" 4 "$(line_count "$out")" &&
    assert_eq "line 4" "$NOTICE" "$(printf '%s\n' "$out" | sed -n 4p)"
}

test_current_shows_nothing() {
  tree_with "$OWN_SHA"
  render >/dev/null
  wait_for_master_change "" || return 1
  grep -q "^$OWN_SHA statusline.sh$" "$CACHE/update-master" || fail "cache lacks own sha" || return 1
  assert_eq "line count" 3 "$(line_count "$(render)")"
}

test_stamp_written_before_and_respected() {
  tree_with "$OWN_SHA"
  render >/dev/null
  local stamp now; stamp=$(cat "$CACHE/update-checked" 2>/dev/null); now=$(date +%s)
  [[ "$stamp" =~ ^[0-9]+$ ]] || fail "stamp not an integer: [$stamp]" || return 1
  [ $((now - stamp)) -le 5 ] || fail "stamp too old: $stamp vs $now" || return 1
  wait_for_master_change "" || return 1
  tree_with "$STALE_SHA"
  local out; out=$(render)
  sleep 0.5
  assert_eq "line count (not due, no refetch)" 3 "$(line_count "$out")" &&
    assert_eq "line count after 0.5s" 3 "$(line_count "$(render)")"
}

test_old_stamp_refetches() {
  seed_cache "$OWN_SHA" $(( $(date +%s) - INTERVAL - 1 ))
  local before; before=$(cat "$CACHE/update-master")
  tree_with "$STALE_SHA"
  render >/dev/null
  wait_for_master_change "$before" || return 1
  assert_eq "line count" 4 "$(line_count "$(render)")"
}

test_disabled() {
  export STATUSLINE_UPDATE_CHECK=0
  mkdir -p "$CACHE"
  printf '%s statusline.sh\n' "$STALE_SHA" > "$CACHE/update-master"
  tree_with "$STALE_SHA"
  local out; out=$(render)
  assert_eq "line count" 3 "$(line_count "$out")" &&
    { [ ! -e "$CACHE/update-checked" ] || fail "stamp written while disabled"; }
}

test_error_body_keeps_cache() {
  seed_cache "$STALE_SHA" $(( $(date +%s) - INTERVAL - 1 ))
  local before; before=$(cat "$CACHE/update-master")
  printf '{"message":"API rate limit exceeded"}' > "$T/tree.json"
  render >/dev/null
  sleep 1
  assert_eq "cache unchanged" "$before" "$(cat "$CACHE/update-master")" &&
    assert_eq "line count" 4 "$(line_count "$(render)")"
}

test_missing_entry() {
  tree_with ""
  render >/dev/null
  wait_for_master_change "" || return 1
  assert_eq "line count" 3 "$(line_count "$(render)")"
}

test_garbage_cache_and_stamp() {
  mkdir -p "$CACHE"
  echo garbage > "$CACHE/update-master"
  echo soon > "$CACHE/update-checked"
  tree_with "$STALE_SHA"
  local out; out=$(render)
  assert_eq "line count with garbage cache" 3 "$(line_count "$out")" || return 1
  wait_for_master_change "garbage" || return 1
  local stamp; stamp=$(cat "$CACHE/update-checked")
  [[ "$stamp" =~ ^[0-9]+$ ]] || fail "stamp not rewritten: [$stamp]"
}

test_hung_fetch_does_not_block() {
  mkfifo "$T/hang"
  export STATUSLINE_UPDATE_URL="file://$T/hang"
  # Pipe stdout like Claude Code does: a leaked background writer would hold it open
  ( render | cat > "$T/out" ) &
  local pid=$! i
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  local running=0
  kill -0 "$pid" 2>/dev/null && running=1
  # curl blocks in open() on a FIFO, which --max-time cannot interrupt: open the
  # FIFO read-write and close it so curl reads EOF and exits
  exec 3<>"$T/hang"; exec 3>&-
  wait "$pid" 2>/dev/null
  [ "$running" -eq 0 ] || fail "render still running after 2s" || return 1
  assert_eq "line count" 3 "$(line_count "$(cat "$T/out")")"
}

test_unwritable_cache_is_silent() {
  touch "$T/blocker"
  export STATUSLINE_UPDATE_CACHE="$T/blocker/cache"
  tree_with "$STALE_SHA"
  render >/dev/null
  assert_eq "stderr (1st render)" "" "$(cat "$T/stderr")" || return 1
  sleep 0.5
  local out; out=$(render)
  assert_eq "line count" 3 "$(line_count "$out")" &&
    assert_eq "stderr (2nd render)" "" "$(cat "$T/stderr")"
}

# ---------- runner ----------

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  ERRORS=""
  setup
  if "$t"; then
    echo "PASS $t"
  else
    echo "FAIL $t"
    printf '%s' "$ERRORS"
    FAILED=$((FAILED + 1))
  fi
  teardown
done

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED test(s) failed"
  exit 1
fi
echo "all tests passed"
