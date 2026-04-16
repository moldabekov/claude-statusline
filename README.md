# claude-statusline

A compact, information-dense status line for [Claude Code](https://claude.com/claude-code).
Three lines of context — identity, session state, telemetry — in monochrome Unicode icons and a handful of emoji (no Nerd Fonts required).

## Preview

```
🖥  [user@host] ▸ ~/Work/Projects/git/claude-statusline ⎇  master ⏳ 38m | ✓ | ●1 +2 ?1 | ↑2 ↓1 | ≡3
⚡ [███░░░░░░░] 35% | ⏱  5h: 12% / 7d: 3% | $1.23 | 🔥 1.7K/m | ✦ Opus 4.7 (max)
🕐 21:46 | 🔋 82% | ⧗ 1h15m | ❄ 88% | ⇅ 125.0K / 4.5K | ☁ prod | 🐍 venv | ▦ work | ⇋ SSH
```

Color-coded thresholds:
- **Context bar** and **rate-limit percentages**: yellow ≥ 60%, red ≥ 80%
- **Burn rate** (`🔥`): green < 3K/m, yellow 3–10K/m, red > 10K/m
- Username in cyan, `[…@host]` in blue, directory in yellow, branch / SSH / tmux in cyan

## Install

```bash
git clone git@github.com:moldabekov/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer copies `statusline.sh` to `~/.claude/statusline.sh` and wires up the
`statusLine` block in `~/.claude/settings.json`. Restart Claude Code to apply.

Requires: `bash`, `jq`, `git`. Optional: `gh` for CI status.

## What each segment shows

### Line 1 — identity
| Segment | Source | Notes |
|---|---|---|
| `🖥  [user@host]` | `$USER`, `$HOSTNAME` | user cyan, `@host` + brackets blue |
| `▸ dir` | `.workspace.current_dir` | yellow, `$HOME` → `~` |
| `⎇  branch` | `git symbolic-ref` | cyan |
| `⏳ age` | `git log -1 --format=%ct` | time since last commit (`s/m/h/d`) |
| `✓ / ✗ / ⋯` | `gh run list` | CI status, cached 60s (needs `gh` auth) |
| `●N +N ?N` | `git status --porcelain` | modified / staged / untracked (only non-zero) |
| `↑N ↓N` | `git rev-list ...@{upstream}` | ahead / behind (only non-zero) |
| `≡N` | `git stash list` | stash count (only when > 0) |
| `\| path` | `.workspace.git_worktree` | worktree path, when present |

### Line 2 — session
| Segment | Source | Notes |
|---|---|---|
| `⚡ [bar] NN%` | `.context_window.used_percentage` | color by threshold |
| `⏱  5h: N% / 7d: N%` | `.rate_limits.*.used_percentage` | each threshold-colored independently |
| `$N.NN` | `.cost.total_cost_usd` | rounded to 2 decimals |
| `🔥 N/m` | `(tokens_in + tokens_out) / session_minutes` | green / yellow / red by burn rate |
| `✦ Model (effort)` | `.model.display_name` + effort level from transcript | effort parsed from `/effort` command output |

### Line 3 — telemetry
| Segment | Source | Conditional |
|---|---|---|
| `🕐 HH:MM` | `date` | always |
| `🔋 NN%` | `/sys/class/power_supply/BAT*/capacity` | only if battery present |
| `⧗ duration` | `.cost.total_duration_ms` | hidden when zero |
| `❄ NN%` | `cache_read / (read + creation)` | hidden when no cache tokens |
| `⇅ in / out` | `.context_window.total_input_tokens`, `.total_output_tokens` | hidden when both zero |
| `☁ profile` | `$AWS_PROFILE` | only if set |
| `🐍 venv` | `$VIRTUAL_ENV` or `.python-version` | only if active / file present |
| `▦ session` | `tmux display-message -p '#S'` | only when inside tmux |
| `⇋ SSH` | `$SSH_CONNECTION` / `$SSH_CLIENT` / `$SSH_TTY` | only on remote sessions, cyan |

## Performance

Expensive calls are cached on disk to keep the statusline snappy:

- **CI status** — `gh run list` runs in the background, cached 60s per `(dir, branch)` to `/tmp/claude-statusline-ci-<hash>`.
- **Git reads** — all local and fast (`status`, `rev-list`, `stash list`, `log -1`) — run synchronously.
- **Kube/Docker** deliberately dropped to avoid slow shelling out.

## Customization

Everything lives in a single `statusline.sh`. Common tweaks:

- **Swap icons**: all emoji/symbols are inline — edit the `echo -e` lines.
- **Change colors**: ANSI codes near the top (`BLUE`, `CYAN`, `YELLOW`, per-segment thresholds).
- **Disable a segment**: comment out its building block — all segments are independent.
- **Progress bar length**: change `10` in the `FILLED` / `EMPTY` calc.
- **Burn rate thresholds**: adjust the `3000` / `10000` cutoffs.

## Troubleshooting

- **`🖥` renders narrow** — the script adds a trailing space to compensate for text-style
  rendering on some terminals. Swap for `🏠`, `💻`, or `🏡` if preferred.
- **CI status missing on first render** — `gh` runs in the background and populates the
  cache; the icon shows up within a second or two on the next render.
- **No battery / env / SSH / tmux metrics** — all conditional, they hide silently when
  the data source isn't present.
- **Leading space trimmed** — Claude Code trims ASCII leading whitespace from statusline
  output; avoid leading spaces at the start of a line.
