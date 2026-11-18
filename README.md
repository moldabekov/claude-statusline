# claude-statusline

Compact, information-dense statuslines for [Claude Code](https://claude.com/claude-code) and
[Pi](https://pi.dev). Both variants show three adaptive lines of identity, session state, and
telemetry using monochrome Unicode icons and a handful of emoji. Only the CPU, RAM, and swap icons
need a [Nerd Font](https://www.nerdfonts.com/); everything else renders with standard fonts.

## Preview

### Claude Code

```text
💻 [user@host] ▸ ~/Work/Projects/git/claude-statusline ⎇ master ⏳ 38m | ✓ 5m | ●1 +2 ?1 | ↑2 ↓1 | ≡3
⚡ [███░░░░░░░] 35% | ⏱ 5h: 12% ↻3h15m / 7d: 3% ↻Apr28 | $1.23 | 🔥 1.7K/m | ✦ Opus 4.7 (max)
🕐 21:46 | ⧗ 1h15m | 󰻠 1.42 | 󰍛 9.8/16G | 󰓦 0.5/2.0G | ❄ 88% | ⇅ 125.0K / 4.5K | ☁ prod | 🐍 venv | ▦ work | ⇋ SSH | 🔋 82%
```

### Pi

```text
💻 [user@host] ▸ ~/Work/Projects/git/claude-statusline ⎇ master | PR #42 ✓ | CI 5✓ | Δ+42−8 | ●1 ?1     ○ idle
⚡ [███░░░░░░░] 35% | CTX 70.0K/200.0K · 130.0K left · ↻1 | $1.23 | 🔥 1.7K/m | ✦ Claude Opus 4.6 (high)
🕐 21:46 | ⧗ 1h15m | 󰻠 1.42 | 󰍛 9.8/16G | 󰓦 0.5/2.0G | ⬡ node22.22 | 🐍 3.13@venv | 🦀 1.91.0 | ❄ 88% | ⇅ 125.0K / 4.5K | ▦ work | 🔋 82%
```

Pi adapts to terminal width, omitting lower-priority segments before truncating. It can also add a
fourth line for statuses published by other Pi extensions.

Color-coded thresholds:

- **Context and rate-limit percentages:** yellow at 60%, red at 80%
- **Burn rate:** green below 3K tokens/min, yellow from 3K–10K, red above 10K
- **Host load:** CPU (load per core), RAM, and swap use yellow at 60%, red at 80%
- **Pi disk:** appears only from 85% full and turns red at 95%

## Install

```bash
git clone git@github.com:moldabekov/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer scans `PATH` and installs the matching statusline for every detected agent:

| Detected command | Installed files |
|---|---|
| `claude` | Copies `statusline.sh` to `~/.claude/statusline.sh` and adds `statusLine` to `~/.claude/settings.json` |
| `pi` | Copies `statusline.ts` to `$PI_CODING_AGENT_DIR/extensions/statusline.ts` when set, otherwise `~/.pi/agent/extensions/statusline.ts` |
| Both | Installs both variants |
| Neither | Exits without installing |

An existing Claude Code `statusLine` setting is left unchanged. Pi discovers the extension
automatically; restart Pi or run `/reload` after installation.

### Requirements

- `bash`
- `git` for repository segments
- `jq` for the Claude Code statusline
- `curl` for the Claude Code update notice
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal for the CPU, RAM, and swap icons
- Optional: authenticated [`gh`](https://cli.github.com/) for CI and pull-request data
- Optional runtime CLIs (`go`, `python3`, `rustc`, `docker`, `kubectl`, and others) are queried by
  Pi only when matching project files are detected; missing tools are ignored

## Claude Code statusline

### Line 1 — identity and Git

| Segment | Source | Notes |
|---|---|---|
| `💻 [user@host]` | `$USER`, `$HOSTNAME` | User cyan, brackets/host blue |
| `▸ dir` | `.workspace.current_dir` | Yellow, `$HOME` contracted to `~` |
| `⎇ branch` | Local Git | Cyan |
| `⏳ age` | Latest commit | Seconds/minutes/hours/days ago |
| `✓ / ✗ / ⋯ / ○` | `gh run list` | Latest run for `HEAD`, including relative age |
| `●N +N ?N` | `git status --porcelain` | Modified, staged, and untracked counts |
| `↑N ↓N` | Git upstream | Ahead/behind counts when non-zero |
| `≡N` | Git stash | Hidden when zero |
| `path` | `.workspace.git_worktree` | Shown for worktrees when provided |

### Line 2 — session

| Segment | Source | Notes |
|---|---|---|
| `⚡ [bar] NN%` | `.context_window.used_percentage` | Ten-cell threshold-colored context meter |
| `⏱ 5h / 7d` | `.rate_limits` | Usage plus reset countdown/date |
| `$N.NN` | `.cost.total_cost_usd` | Hidden when zero |
| `🔥 N/m` | Tokens divided by active duration | Session-average token rate |
| `✦ Model (effort)` | Model and transcript | Effort appears after an explicit `/effort` change |

### Line 3 — telemetry

| Segment | Source | Conditional |
|---|---|---|
| `🕐 HH:MM` | Local clock | Always |
| `⧗ duration` | `.cost.total_duration_ms` | Hidden when zero |
| `󰻠 N.NN` | 1-minute load average (`/proc/loadavg`, `sysctl vm.loadavg`) | Linux and macOS; colored by load per core |
| `󰍛 used/totalG` | Linux `MemTotal − MemAvailable`; macOS app + wired + compressed (`vm_stat`) | Linux and macOS; macOS uses the same components as Activity Monitor's "Memory Used" |
| `󰓦 used/totalG` | Swap from `/proc/meminfo` or `sysctl vm.swapusage` | Hidden when no swap is configured |
| `❄ NN%` | Cache read/write tokens | Hidden without cache tokens |
| `⇅ in / out` | Context token totals | Hidden when both are zero |
| `☁ profile` | `$AWS_PROFILE` | AWS profile set |
| `🐍 env` | `$VIRTUAL_ENV` or `.python-version` | Python environment detected |
| `▦ session` | tmux | Inside tmux |
| `⇋ SSH` | SSH environment | Remote session |
| `🔋 NN%` | Linux power supply or macOS `pmset -g batt` | Battery devices only; always the last segment |

## Pi statusline

Pi’s TypeScript extension replaces the built-in footer while preserving statuses from other
extensions.

### Line 1 — project and live activity

- Responsive user/host, project path, optional Pi session name, Git branch, commit age, dirty state,
  diff size, upstream divergence, stashes, and worktree
- GitHub pull-request state, review decision, unresolved review threads, CI/test/quality check counts
- Latest test, lint, and type-check result when those commands are run through Pi’s `bash` tool
- Right-aligned live state: active tool and elapsed time, thinking, queued work, or idle

### Line 2 — context and model

- Context meter plus used/total/remaining tokens and compaction count
- Provider quota windows when compatible rate-limit headers are available
- Cumulative session cost, token burn rate, model, and thinking level

### Line 3 — project-aware telemetry

- Leads with session age, then host load: CPU load average, RAM, and swap, computed the same way as
  the Claude Code statusline (on other platforms, RAM comes from Node and swap is hidden)
- Adds a disk warning only when the working directory's filesystem is nearly full
- Shows versions only for runtimes detected in the current project: Go, Node.js, Python, Rust, Zig,
  Java, and Terraform
- Detects containers, Docker context, Kubernetes context, AWS profile/region, tmux, and SSH
- Includes cache ratio and cumulative input/output tokens
- Ends with battery level (Linux sysfs or macOS `pmset`); as the last segment, it is the first to be
  dropped on narrow terminals

## Update notice (line 4)

Both statuslines add a fourth line, a bold black-on-orange badge, when your installed copy differs
from the same file on `master`:

```
 󰚰 Update available — statusline.sh changed on master · git pull && ./install.sh
```

- Claude Code checks only `statusline.sh` and Pi checks only `statusline.ts`. Commits that touch
  neither (README, `install.sh`, docs) never trigger it.
- At most every 6 hours, one request to the GitHub tree API fetches the git blob hashes of both
  files on `master`. Each statusline compares its hash with that of its own installed file. No file
  content is downloaded.
- The result is cached in `${XDG_CACHE_HOME:-~/.cache}/claude-statusline/` and shared by both
  agents, so they make one request per 6 hours between them.
- Offline, GitHub errors, and rate limits (60 unauthenticated requests per hour per IP) show nothing.
  The check never delays the statusline.
- A local edit that you installed but haven't pushed also shows the notice, until you push and the
  next check runs.
- To update, run `git pull && ./install.sh` in your clone. The notice clears on the next render.

| Variable | Effect |
|---|---|
| `STATUSLINE_UPDATE_CHECK=0` | Disables the check and the notice |
| `STATUSLINE_UPDATE_CACHE` | Overrides the cache directory |
| `STATUSLINE_UPDATE_URL` | Overrides the tree API URL (used by tests, or to point at a fork) |

## Performance

### Claude Code

- CI status is cached for 60 seconds per directory and `HEAD` under `/tmp` and refreshed in the
  background.
- Local Git reads run synchronously; Kubernetes and Docker calls are deliberately omitted.

### Pi

- Footer rendering uses cached state; external commands never run in the render path.
- Git state and host RAM/swap refresh every 10 seconds, GitHub data at most every 60 seconds, and
  system/runtime data every 60 seconds. The CPU load average is read live on each render.
- Runtime commands are gated by project-file detection, and all subprocesses are cancelled when the
  footer is disposed.

## Customization

- Edit `statusline.sh` for Claude Code.
- Edit `statusline.ts` for Pi, then rerun `./install.sh` or copy it to the Pi extensions directory.
- Run the tests with `bash tests/run.sh`. The TypeScript tests need Pi installed, because they borrow
  its `pi-tui` package; set `PI_TUI_DIR` if it isn't found.
- Icons, colors, thresholds, refresh intervals, and segment ordering are inline in each file.
- Pi colors use the active Pi theme and update automatically when the theme changes.

## Troubleshooting

- **Only one statusline was installed:** the installer only targets `claude` and `pi` commands found
  in `PATH`.
- **Claude installation reports missing `jq`:** install `jq`, then rerun `./install.sh`.
- **Pi statusline does not appear:** restart Pi or run `/reload`.
- **CI/PR data is absent:** install `gh` and run `gh auth login`.
- **Update notice stays after you pushed:** the cached `master` hashes refresh only every 6 hours.
  Delete `~/.cache/claude-statusline/update-checked` to check on the next render.
- **Battery, runtime, cloud, tmux, or SSH segments are absent:** these are conditional and hide when
  unavailable or irrelevant to the current project.
- **Host icon renders narrow:** swap `💻` for `🏠`, `🖥`, or `🏡` in the relevant statusline file.
- **CPU, RAM, or swap icon shows as a box:** the terminal font is not a Nerd Font. Install one, or
  replace `ICON_CPU`, `ICON_RAM`, and `ICON_SWAP` in either file with plain symbols such as `▣ ▤ ⇄`.
