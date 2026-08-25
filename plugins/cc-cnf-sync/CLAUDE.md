# CLAUDE.md — cc-cnf-sync

Agent notes for this plugin. Read [the repo root CLAUDE.md](../../CLAUDE.md) first for
marketplace-wide conventions (git flow, versioning, portability). User docs: `README.md`,
`ROADMAP.md`, and each `commands/*.md`.

## What it does

Backs up Claude Code config to a private GitHub repo (`claude-code-config`), and keeps
**per-project memory** and **global user config** in continuous two-way sync across
machines/OS via `SessionStart`/`SessionEnd` hooks.

## Two halves

1. **Commands** (`commands/*.md`, run by the agent): `/setup`, `/export`, `/import`, `/status`,
   `/memory`, `/sessions`, `/config`, `/uninstall`. One-shot, user-invoked.
2. **The hook** (`hooks/sync-memory.sh`, run by Claude Code on session start/end): automatic,
   continuous, bidirectional memory + global-config sync. This is the heart of the plugin.

## Authentication (v4.0.0+) — GitHub CLI only

- **No MCP. No token stored by the plugin.** All auth is delegated to **`gh`**. `gh` keeps the
  credential in the OS credential store; `gh auth setup-git` wires `git` to use it.
- **`/setup` auto-installs `gh` if missing** (v4.1.0): winget (`--scope user`, no UAC) on Windows,
  `brew` on macOS, non-interactive distro package manager on Linux; exit 3 only if that can't run
  or a restart is needed for `PATH`.
- Commands call `gh` (`gh auth status`, `gh repo view/create`, `gh repo clone`, `gh api … Accept: raw`).
- **The hook has never used the MCP** and still doesn't — it authenticates through git's
  credential helper (which `gh` provides). Nothing changed in the hook for v4.0.
- The only file the plugin writes is `~/.config/cc-cnf-sync/repo` (non-secret backup URL).
- Legacy: pre-4.0 setups installed a `github` MCP and saved `~/.config/cc-cnf-sync/token`. That
  token is no longer read; `/uninstall` cleans it up.

## ⚠️ Critical invariant — `norm_key()` is triplicated

The memory key function `norm_key()` MUST stay **functionally identical** (same input → same key)
in all three:
- `hooks/sync-memory.sh`
- `commands/export.md`
- `commands/memory.md`

If you change one, change all three, or memory folders stop resolving across machines. The key
derivation: `git remote origin → norm_key → key`; fallbacks `local/<folder>` (no remote) then
`slug/<slug>` (no cwd). `safeKey` = key with non-`[a-z0-9._-]` → `-`; it's the folder name under
`memory/`.

**Input comes from `$nk_arg`, NOT a positional `$1`** — see the slash-command gotcha below. All
three read `k=$nk_arg` and are called as `nk_arg=<value>; key=$(norm_key)`, so they stay identical.

## Per-machine state files — NEVER back these up

Kept inside a project's local `memory/` dir, dot-prefixed so the `*.md`-only sync ignores them:
- `.cc-cnf-sync-base` — 3-way merge base (hash of each note as last synced).
- `.cc-cnf-sync-conflicts` — which `.conflict.md` files this machine materialized.
- `.cc-cnf-sync-checked` — marker (lives in the project dir, not memory/).

`/export` must exclude `.cc-cnf-sync-*` from the uploaded tree (regression source — see v3.5.2).
The global-config 3-way bases live in `~/.config/cc-cnf-sync/` (`config-base`), not in the repo.

## Sync algorithm (hook) — key rules

- **Never lose a note.** Fail-open: any error exits 0 without disturbing the session.
- Per project: `fetch → reset --hard to remote → file-level union merge with local → commit →
  push` (retried on push races) → copy merged result back to local.
- **3-way merge** vs `.cc-cnf-sync-base`: editing a note on one side only = that edit wins, no
  conflict. Both sides changed since base = real conflict → keep local as `<n>.md`, remote as
  `<n>.conflict.md` on both sides.
- `MEMORY.md` = 3-way **line** merge keyed by each line's link target (`](<note>.md)`), not by
  its text — a reworded entry replaces the old line instead of piling up next to it, and an entry
  deleted on one machine stays deleted. The ancestor is `.cc-cnf-sync-memory-base` (a copy of the
  index as last synced, written by `record_bases`, never itself synced). No base yet → plain union,
  which never deletes. An empty merge result is never written; the local index is restored from the
  backup instead.
  Within one side, a target repeated twice keeps the position of the first line but the text of
  the LAST — duplicates are appended, so the last one is the current wording.
- **Real-note deletions do NOT propagate** (safety — a plain `rm` reappears from the other
  machine). Deliberate deletion is only via `/memory delete`, which drops a `<n>.md.deleted`
  tombstone. `.conflict.md` deletions DO propagate via `<n>.conflict.md.deleted` tombstones.
  A restored note that this machine HAD at the last sync (i.e. it is listed in
  `.cc-cnf-sync-base`) is NAMED in the SessionStart message, with the pointer to `/memory
  delete`. Silence there is what turned delete → restore → delete into an unexplainable loop.
- **Global config** (`sync_config`): strict allowlist — `CLAUDE.md settings.json keybindings.json
  plugins.json` + `commands/ skills/ agents/` trees. `settings.local.json` is intentionally NOT
  synced. Same 3-way logic; conflicts saved as `.cc-conflict` sidecars.
- **System agent skills** (`sync_config`, same 3-way logic): `~/.agents/skills/` (skill.sh & co., a
  cross-tool skills home OUTSIDE `~/.claude`) mirrored under the cache namespace `agents-skills/`, plus
  the portable `~/.agents/.skill-lock.json` → `agents-skill-lock.json`. No-op when `~/.agents` is absent.
  Recorded in the 3-way base under the same `agents-skills/…` / `agents-skill-lock.json` relpaths.
- **VSCode profile** (`sync_config`, **OPT-IN**): gate `vscode_enabled` reads `vscode_sync=on` from
  `$CFG_DIR/config` (written by `/config`). When on + VSCode present, mirrors the *User* dir
  (`settings.json keybindings.json tasks.json locale.json argv.json` + `snippets/` + a regenerated
  `extensions.txt` from `code --list-extensions`, cached at `$CFG_DIR/vscode-extensions.txt`) under
  `vscode/`. `globalStorage/workspaceStorage/History/sync/` are NEVER touched. `/import` restores it and
  reinstalls extensions via `code --install-extension`. Test seam: `CC_SYNC_VSCODE_HOME`. Default OFF.
- `SessionEnd` runs **detached** (backgrounded) so app teardown can't cancel the push;
  `SessionStart` re-syncs regardless, so nothing is lost either way.

## The memory manifest is ADDITIVE

`memory-manifest.json` (schema 2) is a **union by `safeKey`** of the previous repo manifest and
this machine's projects. Never prune entries for projects that live on other machines. `/export`
merges the prev manifest (fetched via `gh api … Accept: raw`) — do not regenerate from scratch.

## Testing seams (env vars, inert in prod)

- `CC_SYNC_LOCAL_REMOTE` — use a plain local bare repo as the remote (offline e2e tests).
- `CC_SYNC_CACHE` — override the cache clone dir (default `~/.claude/cc-cnf-sync/cache/config`).
- `CC_SYNC_CONFIG_HOME` — override `~/.claude` for the global-config sync.
- `CC_SYNC_AGENTS_HOME` — override `~/.agents` for the system agent-skills sync.
- `CC_SYNC_VSCODE_HOME` — override the VSCode *User* dir for the opt-in VSCode sync.
- `CC_SYNC_INPUT` / `CC_SYNC_BG` — used by the SessionEnd detach re-invocation.

## /sessions — chat transcripts, NOT synced

`/sessions` manages a project's raw transcripts (`~/.claude/projects/<slug>/*.jsonl`) — list/delete/clean/
rename, or `all` across projects. These are **never** backed up (only each project's `memory/` is), so
deleting them just reclaims disk. The locator matches a project dir by comparing each transcript's `cwd`
(read with `grep -oh '"cwd":"…"' | cut`, never sed-over-jsonl) to `$PWD`, both normalized via
`tr '\\' '/'` (NOT backslash-sed). **Rename** appends a `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`
record — Claude Code shows the *last* `ai-title` — JSON-escaping `"`/`\` in the title.

## ⚠️ Slash-command `$1`/`$0` substitution (bit us in v3.x → fixed v4.0.1)

Claude Code substitutes `$1`, `$2`, … `$9`, `$0` and `$ARGUMENTS` inside a **command `.md`'s bash
blocks** with the invocation's arguments — even inside single-quoted strings and awk programs.
With no args, `k=$1` runs as `k=` and `awk '{print $0}'` as `awk '{print }'`. This silently broke
`norm_key()` (empty keys) and the manifest join. **Never use positional params in a command's
bash**: read inputs from a named var (`$nk_arg`), and join/parse without awk `$0` (we use
`sed '$!s/$/,/'`). `$ARGUMENTS` is the ONE intended exception (used by `/memory`). The hook is a
plain script (not slash-substituted) but mirrors the `$nk_arg` form to keep `norm_key()` identical.

## Git Bash gotchas (this plugin is tested on Windows)

- `sed -n 's/…/p'` over `.jsonl` files aborts with "unterminated `s' command" → use `grep | cut`.
- Windows cwd from a transcript is JSON-escaped (`C:\\Users\\…`); normalize with
  `tr '\\' '/' | sed 's#//*#/#g'`, not a backslash-`sed`.
- Command substitution `$(...)` strips trailing newlines — put closing `\n` in the format string.

## Files & locations

- Cache clone of the backup: `~/.claude/cc-cnf-sync/cache/config`.
- Plugin config: `~/.config/cc-cnf-sync/` (`repo`, `config-base`; legacy `token`).
- Local memory: `~/.claude/projects/<slug>/memory/*.md`.
