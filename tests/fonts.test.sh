#!/bin/bash
# Tests for install-fonts.sh. Each test runs in a subshell with a temp HOME, a fake
# fc-list/fc-cache on PATH, and a local font archive. Usage: bash tests/fonts.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
ERRORS=""

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/home" "$T/bin" "$T/archive"
  # Fake archive shaped like NerdFontsSymbolsOnly.tar.xz
  for f in SymbolsNerdFont-Regular.ttf SymbolsNerdFontMono-Regular.ttf LICENSE README.md 10-nerd-font-symbols.conf; do
    echo "$f" > "$T/archive/$f"
  done
  tar -cJf "$T/fonts.tar.xz" -C "$T/archive" .
  : > "$T/fc-list.out"
  printf '#!/bin/sh\necho "$@" >> "%s/fc-list.args"\ncat "%s/fc-list.out"\n' "$T" "$T" > "$T/bin/fc-list"
  printf '#!/bin/sh\necho "$@" >> "%s/fc-cache.log"\n' "$T" > "$T/bin/fc-cache"
  chmod +x "$T/bin/fc-list" "$T/bin/fc-cache"
}

teardown() { rm -rf "$T"; }

fail() { ERRORS+="    $1"$'\n'; return 1; }

target_dir() {
  if [[ "$OSTYPE" == darwin* ]]; then echo "$T/home/Library/Fonts"; else echo "$T/home/.local/share/fonts/NerdFontsSymbolsOnly"; fi
}

# Run fonts_main in a clean subshell: <interactive 0|1> <stdin> [VAR=value ...]
# Leaves output in $T/out and the exit status in $T/status
run_fonts() {
  local interactive=$1 input=$2; shift 2
  (
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY TERM_PROGRAM XDG_DATA_HOME
    export HOME="$T/home" PATH="$T/bin:/usr/bin:/bin"
    for assignment in "$@"; do export "${assignment?}"; done
    # shellcheck source=/dev/null
    source "$ROOT/install-fonts.sh"
    FONT_URL="file://$T/fonts.tar.xz"
    FONT_SHA256=$( (sha256sum "$T/fonts.tar.xz" 2>/dev/null || shasum -a 256 "$T/fonts.tar.xz") | cut -d' ' -f1)
    FONT_SEARCH_DIRS=("$T/home/Library/Fonts")
    [ -n "${OVERRIDE_URL:-}" ] && FONT_URL=$OVERRIDE_URL
    [ -n "${OVERRIDE_SHA:-}" ] && FONT_SHA256=$OVERRIDE_SHA
    if [ "$interactive" = 1 ]; then fonts_interactive() { return 0; }; else fonts_interactive() { return 1; }; fi
    printf '%s\n' "$input" | fonts_main
  ) > "$T/out" 2>&1
  echo $? > "$T/status"
}

out_has() { grep -qF -- "$1" "$T/out" || fail "output lacks [$1]: $(tr '\n' ' ' < "$T/out")"; }
status_is() { [ "$(cat "$T/status")" = "$1" ] || fail "status $(cat "$T/status"), expected $1"; }
nothing_installed() { [ -z "$(ls -A "$(target_dir)" 2>/dev/null)" ] || fail "fonts were installed: $(ls "$(target_dir)")"; }

# ---------- tests ----------

test_skips_over_ssh() {
  run_fonts 1 y SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
  status_is 0 && out_has "SSH" && nothing_installed
}

test_skips_in_ghostty() {
  run_fonts 1 y TERM_PROGRAM=ghostty
  status_is 0 && out_has "built in" && nothing_installed
}

test_skips_in_wezterm() {
  run_fonts 1 y TERM_PROGRAM=WezTerm
  status_is 0 && out_has "built in" && nothing_installed
}

test_skips_when_font_has_glyphs() {
  echo "FiraCode Nerd Font" > "$T/fc-list.out"
  run_fonts 1 y
  status_is 0 && out_has "already installed" && nothing_installed &&
    { grep -q "f09d1" "$T/fc-list.args" && grep -q "f302" "$T/fc-list.args" || fail "fc-list not asked for both glyphs: $(cat "$T/fc-list.args")"; }
}

test_noninteractive_prints_instructions() {
  run_fonts 0 y
  status_is 0 && out_has "./install-fonts.sh" && out_has "download file://$T/fonts.tar.xz" && nothing_installed
}

test_declined() {
  run_fonts 1 n
  status_is 0 && out_has "[y/N]" && out_has "skipped" && nothing_installed
}

test_default_is_no() {
  run_fonts 1 ""
  status_is 0 && nothing_installed
}

test_installs_on_yes() {
  run_fonts 1 y
  status_is 0 || return 1
  local dir; dir=$(target_dir)
  [ -f "$dir/SymbolsNerdFont-Regular.ttf" ] && [ -f "$dir/SymbolsNerdFontMono-Regular.ttf" ] ||
    fail "fonts missing in $dir: $(ls "$dir" 2>&1)" || return 1
  [ "$(ls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "extra files copied: $(ls "$dir")" || return 1
  out_has "installed Symbols Nerd Font" || return 1
  if [[ "$OSTYPE" != darwin* ]]; then
    grep -q -- "-f" "$T/fc-cache.log" 2>/dev/null || fail "fc-cache -f not run"
  fi
}

test_checksum_mismatch() {
  run_fonts 1 y OVERRIDE_SHA=0000000000000000000000000000000000000000000000000000000000000000
  status_is 1 && out_has "checksum" && nothing_installed
}

test_download_failure() {
  run_fonts 1 y OVERRIDE_URL="file://$T/missing.tar.xz"
  status_is 1 && out_has "download failed" && nothing_installed
}

test_iterm_hint() {
  run_fonts 1 y TERM_PROGRAM=iTerm.app
  status_is 0 && out_has "non-ASCII"
}

test_vscode_hint() {
  run_fonts 1 y TERM_PROGRAM=vscode
  status_is 0 && out_has "terminal.integrated.fontFamily"
}

test_mac_without_fc_list_finds_v3_file() {
  [[ "$OSTYPE" == darwin* ]] || return 0
  [ -x /usr/bin/fc-list ] && return 0
  rm "$T/bin/fc-list"
  mkdir -p "$T/home/Library/Fonts"
  touch "$T/home/Library/Fonts/FiraCodeNerdFont-Regular.ttf"
  run_fonts 1 y
  status_is 0 && out_has "already installed"
}

test_mac_without_fc_list_reports_v2() {
  [[ "$OSTYPE" == darwin* ]] || return 0
  [ -x /usr/bin/fc-list ] && return 0
  rm "$T/bin/fc-list"
  mkdir -p "$T/home/Library/Fonts"
  touch "$T/home/Library/Fonts/Fira Code Nerd Font Complete.ttf"
  run_fonts 0 y
  status_is 0 && out_has "v2"
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
