# Font check — design

## Intent

The statusline icons are Nerd Fonts v3 glyphs. A machine without a v3 Nerd Font shows
boxes or wrong icons. The installer should notice that and, only with the user's consent,
install the symbols-only Nerd Font.

## Decided with the user

- Lives in the installer (`install-fonts.sh`, run by `install.sh` and runnable alone).
  The statusline never prompts.
- Installs **Symbols Nerd Font** (both `SymbolsNerdFont-Regular.ttf` and
  `SymbolsNerdFontMono-Regular.ttf`) from Nerd Fonts **v3.5.1**, pinned, verified against
  SHA-256 `01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996`
  (matches the release's `SHA-256.txt`, checked 2026-11-19). The user's main font stays.
- User font dir only, no sudo: `~/Library/Fonts` (macOS), `~/.local/share/fonts/NerdFontsSymbolsOnly`
  (Linux, then `fc-cache -f`).
- Prompt `[y/N]`, default no; non-interactive runs print instructions only.

## Rules

1. Skip (exit 0, one line why) when:
   - SSH session (`SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY`): fonts belong on the local machine.
   - `TERM_PROGRAM` is `ghostty` or `WezTerm`: symbols are built in.
   - A font already has both U+F09D1 (nf-md v3) and U+F302 (nf-linux):
     `fc-list ':charset=f09d1 f302'` prints anything. Without `fc-list` on macOS, any
     `*NerdFont*` file in `~/Library/Fonts` or `/Library/Fonts` counts.
2. Without `fc-list` on macOS, v2-named files (`*Nerd Font Complete*`) are reported as too old.
3. Download/checksum/extract failure: message, nothing installed, return 1; `install.sh`
   still succeeds (the statusline is installed either way).
4. After installing, one hint for the terminal: iTerm2 (non-ASCII font), VS Code
   (`terminal.integrated.fontFamily`), Terminal.app (pick a Nerd Font if boxes remain),
   Linux (restart the terminal).

## Approaches considered

- **Symbols-only font as fallback (chosen):** keeps the user's font; Linux fontconfig falls
  back automatically.
- Full Nerd Font (e.g. JetBrainsMono Nerd Font): only helps if the user switches fonts.
- Configure iTerm2 automatically: invasive; a printed hint instead.
