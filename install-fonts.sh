#!/bin/bash
# Checks for a Nerd Fonts v3 font with the statusline icons and, only with your consent,
# installs Symbols Nerd Font into your user font directory (no sudo).
# Usage: ./install-fonts.sh   (install.sh runs it too; tests source it as a library)

FONT_VERSION="v3.5.1"
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/NerdFontsSymbolsOnly.tar.xz"
FONT_SHA256="01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996"
FONT_SIZE_LABEL="2.3 MB"
# nf-md-brain exists only in Nerd Fonts v3+; nf-linux-apple covers the OS logos
FONT_TEST_CHARSET="f09d1 f302"
FONT_SEARCH_DIRS=("$HOME/Library/Fonts" "/Library/Fonts")

fonts_say() { echo "Fonts: $*"; }

fonts_target_dir() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "$HOME/Library/Fonts"
  else
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/fonts/NerdFontsSymbolsOnly"
  fi
}

# macOS without fc-list: look for font files by their Nerd Fonts naming
fonts_find_files() { # <glob>
  local dir
  for dir in "${FONT_SEARCH_DIRS[@]}"; do
    compgen -G "$dir/$1" >/dev/null && return 0
  done
  return 1
}

fonts_have_glyphs() {
  if command -v fc-list >/dev/null 2>&1; then
    [ -n "$(fc-list ":charset=${FONT_TEST_CHARSET}" family 2>/dev/null)" ]
    return
  fi
  [[ "$OSTYPE" == darwin* ]] && fonts_find_files "*NerdFont*"
}

# Prints why no font is needed here, or nothing
fonts_skip_reason() {
  if [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
    echo "SSH session; icons are drawn by the terminal on the machine you type on, so install fonts there"
    return
  fi
  case "${TERM_PROGRAM:-}" in
    ghostty|WezTerm) echo "${TERM_PROGRAM} has the Nerd Font symbols built in"; return ;;
  esac
  if fonts_have_glyphs; then echo "a Nerd Fonts v3 font is already installed"; fi
}

fonts_interactive() { [ -t 0 ] && [ -t 1 ]; }

fonts_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Download, verify, and copy only the .ttf files; returns 1 on any failure
fonts_install() {
  local tmp target font copied=0
  tmp=$(mktemp -d) || return 1
  target=$(fonts_target_dir)
  if ! curl -fsSL --max-time 120 "$FONT_URL" -o "$tmp/fonts.tar.xz" 2>/dev/null; then
    fonts_say "download failed: $FONT_URL"
  elif [ "$(fonts_sha256 "$tmp/fonts.tar.xz")" != "$FONT_SHA256" ]; then
    fonts_say "checksum mismatch, not installing"
  elif ! mkdir -p "$tmp/unpacked" || ! tar -xJf "$tmp/fonts.tar.xz" -C "$tmp/unpacked" 2>/dev/null; then
    fonts_say "could not unpack the archive (is xz installed?)"
  elif ! mkdir -p "$target"; then
    fonts_say "could not create $target"
  else
    for font in "$tmp/unpacked"/*.ttf; do
      [ -f "$font" ] && cp "$font" "$target/" && copied=$((copied + 1))
    done
  fi
  rm -rf "$tmp"
  if [ "$copied" -eq 0 ]; then return 1; fi
  if [[ "$OSTYPE" != darwin* ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$target" >/dev/null 2>&1
  fi
  fonts_say "installed Symbols Nerd Font ${FONT_VERSION} to $target"
}

fonts_hint() {
  case "${TERM_PROGRAM:-}" in
    iTerm.app)
      fonts_say "in iTerm2, open Settings → Profiles → Text, turn on \"Use a different font for non-ASCII text\", and pick Symbols Nerd Font Mono" ;;
    vscode)
      fonts_say "in VS Code, append Symbols Nerd Font Mono to terminal.integrated.fontFamily, e.g. \"Menlo, 'Symbols Nerd Font Mono'\"" ;;
    Apple_Terminal)
      fonts_say "if Terminal.app still shows boxes, pick a Nerd Font in Settings → Profiles → Text → Font" ;;
    *)
      if [[ "$OSTYPE" == darwin* ]]; then
        fonts_say "restart your terminal; if icons still show as boxes, set Symbols Nerd Font Mono as its fallback font"
      else
        fonts_say "restart your terminal to pick up the font"
      fi ;;
  esac
}

fonts_main() {
  local reason answer
  reason=$(fonts_skip_reason)
  if [ -n "$reason" ]; then
    fonts_say "skipped: $reason"
    return 0
  fi
  if [[ "$OSTYPE" == darwin* ]] && ! command -v fc-list >/dev/null 2>&1 && fonts_find_files "*Nerd Font Complete*"; then
    fonts_say "found Nerd Fonts v2 files; they lack many of the statusline icons"
  fi
  if ! fonts_interactive; then
    fonts_say "no Nerd Fonts v3 font found. Run ./install-fonts.sh in a terminal to install Symbols Nerd Font, or download $FONT_URL"
    return 0
  fi
  printf 'Fonts: no Nerd Fonts v3 font found. Install Symbols Nerd Font %s (%s, github.com/ryanoasis/nerd-fonts) into %s? [y/N] ' \
    "$FONT_VERSION" "$FONT_SIZE_LABEL" "$(fonts_target_dir)"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|Yes|YES) fonts_install && fonts_hint ;;
    *) fonts_say "skipped; icons may show as boxes until a Nerd Font is installed" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fonts_main
fi
