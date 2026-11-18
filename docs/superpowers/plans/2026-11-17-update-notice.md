# Update Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a 4th statusline line when the installed `statusline.sh` (Claude Code) or `statusline.ts` (Pi) differs from the same file on `master`.

**Architecture:** Every 6 h, one agent fetches the GitHub tree API for `master`, extracts the blob SHAs of `statusline.sh` and `statusline.ts`, and writes them to a shared cache. On every render each agent compares its own file's git blob SHA with the cached one. Fetching never blocks rendering.

**Tech Stack:** bash + curl + jq + git (Claude Code); TypeScript on Node 24, `fetch`, `node:crypto`, `node:test` (Pi).

**Spec:** `docs/superpowers/specs/2026-11-17-update-notice-design.md`

## Global Constraints

- Tree API URL: `https://api.github.com/repos/moldabekov/claude-statusline/git/trees/master`
- Check interval: 6 h (`21600` s / `21_600_000` ms). No other interval.
- Cache dir: `${STATUSLINE_UPDATE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}`; files `update-checked` (epoch seconds, one line) and `update-master` (`<40-hex sha> <path>` lines). Both agents share them.
- `update-checked` is written **before** the request.
- Overrides: `STATUSLINE_UPDATE_URL` (tree URL), `STATUSLINE_UPDATE_CACHE` (dir), `STATUSLINE_UPDATE_CHECK=0` (disable: no fetch, no notice).
- Notice text (exact, leading and trailing space): ` 󰚰 Update available — <file> changed on master · git pull && ./install.sh ` where `<file>` is `statusline.sh` or `statusline.ts`; icon is U+F06B0.
- Notice style: SGR `\033[1;38;5;16;48;5;208m` … `\033[0m`. Steady, no blink.
- Notice is its own line after line 3, only when the cached SHA exists, is valid, and differs from the local SHA. Battery stays the last item on line 3.
- Any failure (offline, HTTP error, bad JSON, missing entry, unwritable cache, missing git) shows nothing and prints nothing to stderr.
- Commits only when the user asks; no Co-Authored-By line.

## Review Focus

1. **Network hangs** (captive portal, dead Wi-Fi): render must still return at once. Pinned by `test_hung_fetch_does_not_block` (FIFO URL) in Task 1.
2. **Rate-limited / error body** (`{"message":"API rate limit exceeded"}`): no notice, previous cache kept. Pinned by `test_error_body_keeps_cache` (Task 1) and `"error body keeps previous cache"` (Task 2).
3. **Unwritable cache dir**: exactly 3 lines, empty stderr. Pinned by `test_unwritable_cache_is_silent` (Task 1).
4. **Corrupt cache or stamp** (partial write, garbage): no notice; garbage stamp counts as due. Pinned by `test_garbage_cache_and_stamp` (Task 1) and `"garbage stamp is due"` (Task 2).
5. **Other agent refreshed the cache**: Pi picks up a cache written by the bash script without fetching again. Pinned by `"uses fresh cache without fetching"` (Task 2).

---

### Task 1: Claude Code update check and notice

**Files:**
- Modify: `statusline.sh` (new block before the final `echo -e` lines; one extra `echo` at the end)
- Create: `tests/update-check.test.sh`

**Interfaces:**
- Produces: the cache file format above, which Task 2 reads and writes.

- [ ] **Step 1: Write the failing tests** in `tests/update-check.test.sh`

  A plain bash runner (no framework): each `test_*` function runs in its own `mktemp -d` dir, copies `statusline.sh` there as `statusline.sh`, and pipes this JSON into `bash <copy>` with `STATUSLINE_UPDATE_CACHE=$tmp/cache`:
  `{"model":{"display_name":"M"},"workspace":{"current_dir":"<tmp>"},"context_window":{"used_percentage":1}}`.
  Fixture `tree.json` = `{"tree":[{"path":"statusline.sh","type":"blob","sha":"<sha>"},{"path":"statusline.ts","type":"blob","sha":"<40 x 'b'>"}]}`, served via `STATUSLINE_UPDATE_URL=file://$tmp/tree.json`. Helper `render_twice` renders once, waits up to 5 s for `cache/update-master`, then renders again. Prints `PASS/FAIL <name>`; exits non-zero on any failure.

  - `test_stale_shows_notice`: fixture sha = 40 × `a` → output has 4 lines; line 4 equals `$'\033[1;38;5;16;48;5;208m 󰚰 Update available — statusline.sh changed on master · git pull && ./install.sh \033[0m'`.
  - `test_current_shows_nothing`: fixture sha = `git hash-object --no-filters <copy>` → 3 lines.
  - `test_stamp_written_before_and_respected`: after the first render `cache/update-checked` holds an integer within 5 s of `date +%s`; then change fixture to stale, render again → still 3 lines (not due).
  - `test_old_stamp_refetches`: stamp = `now - 21601`, cache says current, fixture says stale → after `render_twice`, 4 lines.
  - `test_disabled`: `STATUSLINE_UPDATE_CHECK=0`, stale cache pre-seeded → 3 lines and `cache/update-checked` not created.
  - `test_error_body_keeps_cache`: pre-seed cache stale + old stamp; fixture `{"message":"API rate limit exceeded"}` → still 4 lines; `update-master` unchanged.
  - `test_missing_entry`: fixture tree without `statusline.sh` → 3 lines.
  - `test_garbage_cache_and_stamp`: `update-master` = `garbage`, `update-checked` = `soon` → first render 3 lines and a fetch happens (stamp becomes an integer).
  - `test_hung_fetch_does_not_block`: `mkfifo $tmp/hang`, URL `file://$tmp/hang` → render finishes in < 2 s, 3 lines; kill leftover curl afterwards.
  - `test_unwritable_cache_is_silent`: `touch $tmp/blocker`; cache dir `$tmp/blocker/cache` (parent is a regular file, so `mkdir` fails even as root in Docker), stale fixture → 3 lines, stderr empty.

- [ ] **Step 2: Run tests, verify they fail**

  Run: `bash tests/update-check.test.sh`
  Expected: `test_stale_shows_notice`, `test_stamp_written_before_and_respected`, `test_old_stamp_refetches`, `test_error_body_keeps_cache`, `test_garbage_cache_and_stamp` FAIL; the rest may pass vacuously.

- [ ] **Step 3: Implement in `statusline.sh`**

  - Constants: `UPDATE_TREE_URL`, `UPDATE_INTERVAL=21600`, `UPDATE_FILE=statusline.sh`, `UPDATE_NOTICE` (exact text), `ORANGE_BADGE='\033[1;38;5;16;48;5;208m'`.
  - `update_cache_dir` → echoes the dir per Global Constraints.
  - `update_check_start <cache_dir>`: if stamp is missing, non-numeric, or older than `UPDATE_INTERVAL`, `mkdir -p` and write `date +%s` to `update-checked` (return silently if that fails), then spawn a detached `( … ) &>/dev/null &` that runs `curl -fsS --max-time 10 "$url"` to a tmp file in the cache dir, runs `jq -r '.tree[]? | select(.type=="blob" and (.path=="statusline.sh" or .path=="statusline.ts")) | "\(.sha) \(.path)"'`, keeps only lines matching `^[0-9a-f]{40} statusline\.(sh|ts)$`, and `mv`s into `update-master` only if non-empty. Always removes tmp files.
  - `update_notice <cache_dir>`: cached sha = the `update-master` line for `$UPDATE_FILE`; local sha = `git hash-object --no-filters "${BASH_SOURCE[0]}"`; echoes `${ORANGE_BADGE}${UPDATE_NOTICE}${RESET}` only when both are 40-hex and differ.
  - Skip both when `STATUSLINE_UPDATE_CHECK=0`. Set `UPDATE_STR` and, after the line-3 `echo`, add `[ -n "$UPDATE_STR" ] && echo -e "$UPDATE_STR"`.
  - Do all of this with stderr suppressed (`2>/dev/null`) so nothing leaks into the statusline.

- [ ] **Step 4: Run tests, verify they pass**

  Run: `bash tests/update-check.test.sh` → all PASS, exit 0.
  Also on Fedora: `docker run --rm -v "$PWD":/w -w /w fedora:latest bash -c 'dnf -q -y install jq git-core curl >/dev/null && bash tests/update-check.test.sh'` → all PASS.

### Task 2: Pi update check and notice

**Files:**
- Modify: `statusline.ts` (exported helpers near the other top-level helpers; footer wiring in `setFooter`; line 4 in `render`)
- Create: `tests/update-check.test.ts`, `tests/run.sh`
- Modify: `.gitignore` (create; add `node_modules/`)

**Interfaces:**
- Consumes: cache format from Task 1.
- Produces (exported from `statusline.ts`):
  - `gitBlobSha(content: Uint8Array): string` — sha1 of `"blob <byteLength>\0"` + bytes, hex.
  - `parseTreeShas(body: unknown): Record<string, string>` — valid `statusline.sh`/`statusline.ts` blob entries only.
  - `formatUpdateCache(shas: Record<string, string>): string` / `parseUpdateCache(text: string): Record<string, string>` — `<sha> <path>\n` lines, 40-hex only.
  - `isUpdateCheckDue(stampText: string | undefined, nowMs: number): boolean`
  - `checkForUpdate(options: { file: string; ownPath: string; cacheDir: string; url: string; nowMs: number; fetchImpl: typeof fetch; signal?: AbortSignal }): Promise<boolean>` — stamp-then-fetch when due, writes cache via tmp + `rename`, returns whether the cached SHA for `file` is valid and differs from the own file's SHA. Never throws.
  - `updateNoticeLine(file: string): string` — exact styled notice.

- [ ] **Step 1: Write the failing tests** in `tests/update-check.test.ts` (`node:test`, `node:assert/strict`, temp dirs via `mkdtemp`)

  - `"gitBlobSha matches git"`: for `Buffer.from("hello\n")` → `ce013625030ba8dba906f756967f9e9ca394464a`.
  - `"parseTreeShas keeps valid entries"`: tree with valid `statusline.ts`, `statusline.sh` with sha `"xyz"`, and `README.md` → `{ "statusline.ts": <sha> }`.
  - `"parseUpdateCache round-trips and rejects garbage"`: `parseUpdateCache(formatUpdateCache(x))` deep-equals `x`; `parseUpdateCache("garbage")` → `{}`.
  - `"garbage stamp is due"`: `isUpdateCheckDue("soon", now)` → true; `isUpdateCheckDue(String(now/1000 - 21599), now)` → false; `- 21601` → true; `undefined` → true.
  - `"stale file reports update"`: fake fetch returns tree with 40 × `a` for `statusline.ts` → `true`; `update-checked` and `update-master` exist.
  - `"current file reports none"`: fake fetch returns own file's `gitBlobSha` → `false`.
  - `"uses fresh cache without fetching"`: stamp = now, cache stale, fetch throws if called → `true`, fetch call count 0.
  - `"error body keeps previous cache"`: stale cache + old stamp, fetch returns `{"message":"API rate limit exceeded"}` with status 403 → `true`, `update-master` unchanged.
  - `"fetch rejection reports none and does not throw"`: empty cache, fetch rejects → `false`.
  - `"updateNoticeLine exact text"`: equals `"\x1b[1;38;5;16;48;5;208m 󰚰 Update available — statusline.ts changed on master · git pull && ./install.sh \x1b[0m"`.

  `tests/run.sh`: runs `bash tests/update-check.test.sh`; then, if `@earendil-works/pi-tui` is found under `$(npm root -g)/@earendil-works/pi-coding-agent/node_modules/` (or `$PI_TUI_DIR`), symlinks it to `node_modules/@earendil-works/pi-tui` and runs `node --test tests/update-check.test.ts`; otherwise prints `SKIP ts tests (pi-tui not found)`. Exit non-zero if any part fails.

- [ ] **Step 2: Run tests, verify they fail**

  Run: `bash tests/run.sh` → TS tests FAIL with missing exports.

- [ ] **Step 3: Implement the helpers in `statusline.ts`**, then wire the footer:
  - Own path: `fileURLToPath(import.meta.url)` when it ends in `statusline.ts`, else `${PI_CODING_AGENT_DIR ?? ~/.pi/agent}/extensions/statusline.ts`.
  - Footer state `updateAvailable = false`, `updateRefreshRunning`, `lastUpdateRefresh`. `scheduleUpdateRefresh()` follows the `scheduleHostRefresh` pattern and calls `checkForUpdate` with `globalThis.fetch` and `AbortSignal.any([abortController.signal, AbortSignal.timeout(10_000)])`. Call it at setup and from the 1 s timer every 60 s (it only fetches when due; the 60 s poll picks up cache written by the other agent). Skip entirely when `STATUSLINE_UPDATE_CHECK === "0"`.
  - In `render`: after `line3`, if `updateAvailable`, push `truncateToWidth(updateNoticeLine("statusline.ts"), terminalWidth, "")` before extension statuses.

- [ ] **Step 4: Run tests, verify they pass**

  Run: `bash tests/run.sh` → all bash and TS tests PASS.

### Task 3: Docs and live check

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README** — add an "Update notice" section: what line 4 means, that it compares the installed file with `master` every 6 h via the GitHub API (60 unauthenticated requests/hour/IP; failures show nothing), that a locally installed unpushed edit also triggers it, how to update (`git pull && ./install.sh`), and the three env vars. Add a "Tests" line: `bash tests/run.sh`.

- [ ] **Step 2: Live check on this Mac**

  Run `./install.sh`, then render twice against the real API:
  `echo '{"model":{"display_name":"M"},"workspace":{"current_dir":"'"$PWD"'"}}' | bash ~/.claude/statusline.sh`
  Expected: line 4 shows, because the new unpushed file differs from `master` (fc938ef). `~/.cache/claude-statusline/update-master` holds both SHAs, matching `git rev-parse origin/master:statusline.sh` / `:statusline.ts`. Pi after `/reload` shows its own notice for the same reason. Both clear once the change is pushed and the next check runs (delete `update-checked` to force it).

- [ ] **Step 3: Hand back** — report results; commit and push only when the user asks.
