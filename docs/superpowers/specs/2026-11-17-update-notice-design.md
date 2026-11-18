# Update notice — design

## Intent

The statusline runs on several machines (macOS, Fedora). Each one is installed by
copying a file out of a clone, so an installed copy silently falls behind `master`
(on 2026-11-17 the Mac's `~/.claude/statusline.sh` was missing fc938ef). The
statusline should say when the installed copy is out of date, so the user knows to
`git pull && ./install.sh`.

## Goals / non-goals

- Goal: a clearly visible notice when the installed file differs from the same file
  on `master` of `moldabekov/claude-statusline`.
- Goal: each agent checks only its own file — Claude Code `statusline.sh`, Pi
  `statusline.ts`. Commits that touch neither (README, install.sh, docs) never notify.
- Non-goal: auto-updating, showing changelogs, or commit counts.
- Anti-goal: slowing down or breaking the statusline. Offline, rate-limited, or
  malformed responses must show nothing, never a false notice, and never block render.

## Approaches considered

1. **Compare git blob hashes (chosen).** One unauthenticated request to
   `https://api.github.com/repos/moldabekov/claude-statusline/git/trees/master`
   (~1.6 KB) lists the blob SHA of every top-level file on `master`. The installed
   file's blob SHA is computed locally and compared. Verified on 2026-11-17: installed
   `statusline.sh` `53f5a95…` vs master `68dcee3…` (stale); installed `statusline.ts`
   `7aba46d…` matches master. No file content is downloaded or stored.
2. Download the raw file from raw.githubusercontent.com and byte-compare — works, but
   transfers 15 KB / 52 KB per check and needs validation of the downloaded body.
3. Stamp the clone's commit at install time and use the GitHub compare API — false
   notices when installing before committing; fails for unpushed commits.
4. `git fetch` in the clone recorded by install.sh — needs background SSH auth and the
   clone to stay put.

Known trade-offs of (1):
- GitHub allows 60 unauthenticated API requests per hour per IP. One check per 6 h
  is far below that; if the limit is hit (shared IP), the check fails and nothing shows.
- A local edit that is installed but not pushed also shows the notice. After it is
  pushed, the notice can stay until the next check (up to 6 h).

## Decided with the user

- Check for updates **every 6 hours**.
- No file download: compare hashes.
- The notice is its own **4th line**, shown only when an update is available.
- **Steady badge, no flashing** (blink is off in the user's terminal; self-animating
  in Claude Code would need `refreshInterval: 1`, rerunning the script every second).
- Colors: **bold black on orange** — SGR `1;38;5;16;48;5;208`. Same in Pi.
- Text: ` 󰚰 Update available — <file> changed on master · git pull && ./install.sh `
  (nf-md-update, U+F06B0).
- Battery stays the last item on line 3.

## Builder's calls

- Local hash: git blob SHA-1 = `sha1("blob <byte length>\0" + bytes)`.
  statusline.sh uses `git hash-object --no-filters "${BASH_SOURCE[0]}"`; statusline.ts
  uses `node:crypto` on its own file.
- Shared cache in `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/`, used by both
  agents so the 6 h interval holds across sessions and agents:
  - `update-checked` — epoch seconds of the last attempt, written before the request
    (so failures also wait 6 h). An epoch file, not `stat`, so BSD tools work.
  - `update-master` — `<sha> <path>` lines for `statusline.sh` and `statusline.ts`,
    written via tmp file + `mv`. Entries are accepted only as 40 hex chars.
  - Missing or unreadable cache means no notice.
- statusline.sh: background `curl -fsS --max-time 10` of the tree API; `jq` extracts
  the entries. Render compares the cached `statusline.sh` SHA with the local one.
- statusline.ts: same files and rules, driven by the existing 1 s timer, `fetch` with
  the footer's abort signal and a 10 s timeout. Own path from `import.meta.url`,
  falling back to `${PI_CODING_AGENT_DIR:-~/.pi/agent}/extensions/statusline.ts`.
  The local hash is cached by file mtime.
- Env overrides for tests and opt-out: `STATUSLINE_UPDATE_URL` (tree API URL),
  `STATUSLINE_UPDATE_CACHE` (cache dir), `STATUSLINE_UPDATE_CHECK=0` (disable).
- README documents the notice, what triggers it, and the opt-out.
