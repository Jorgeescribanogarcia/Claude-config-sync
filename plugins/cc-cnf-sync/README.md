# cc-cnf-sync

Back up your entire Claude Code setup — `settings.json`, `CLAUDE.md`, custom commands, skills, agents,
installed plugins, **system-level agent skills** (`~/.agents/skills`, e.g. from [skill.sh](https://skill.sh)),
and **per-project memory** — to a **private GitHub repository**, and keep it **continuously in sync across
all your machines** (Linux, macOS, Windows).

Authentication is entirely through the **GitHub CLI (`gh`)** — the plugin never stores a token; `gh` keeps
the credential in your OS credential store and wires `git` (and the sync hook) to use it. Backups are
**portable**: instead of copying machine-specific plugin paths, it stores a small `plugins.json` manifest
(which plugins, from which marketplaces) and rebuilds them with the Claude Code CLI on restore — so the same
setup works under any username or OS.

Conversation transcripts (sessions) are intentionally **not** backed up — they're large and may contain
sensitive pasted content.

---

## Two ways your setup stays in sync

cc-cnf-sync works on two levels, both writing to the same private `claude-code-config` repo on your account:

1. **Continuous automatic sync (the hook) — you run nothing.** A `SessionStart`/`SessionEnd` hook fires
   every time you open or close Claude Code and does a **two-way, conflict-safe** sync of your **per-project
   memory**, your **global user config** (`CLAUDE.md`, commands, skills, agents, settings, keybindings, the
   plugin manifest) and your **system agent skills** — it pulls the latest from your backup, merges it with
   what's on this machine, and pushes your changes back. Edit a note or your global `CLAUDE.md` on one
   machine and it reaches the others automatically. Divergent edits keep **both** copies — nothing is lost.

2. **On-demand full snapshot (`/export` + `/import`).** `/export` uploads a complete snapshot; `/import`
   restores it on another machine and rebuilds your plugins there. Use these for your **first** backup, to
   set up a **fresh machine**, or as a manual belt-and-suspenders snapshot on top of the continuous sync.

**Cross-platform:** everything runs through `bash` (on Windows, Claude Code's bundled Git Bash), and
`~/.claude` / `~/.agents` resolve to the right location on every OS — no PowerShell required.

## What gets backed up

| Included | Excluded (for security / privacy) |
|---|---|
| `settings.json`, `CLAUDE.md`, `keybindings.json` | `.credentials.json`, `settings.local.json` |
| `commands/`, `skills/`, `agents/` | `history.jsonl`, `~/.claude.json` |
| System agent skills — `~/.agents/skills/` + `.skill-lock.json` (skill.sh & co.) | Machine-specific plugin caches & absolute paths |
| `plugins.json` — portable plugin/marketplace manifest | |
| Per-project memory (`projects/<project>/memory/`) | Session transcripts (`projects/*.jsonl`) |

`settings.local.json` is **never** synced — that's where anything machine-specific belongs.

---

## How the continuous sync works

The hook (`hooks/sync-memory.sh`, wired to `SessionStart` + `SessionEnd`) is the always-on engine. Per
session, for the project you have open:

```
1. compute the project's git-remote key (stable across machines/OS)
2. fetch the backup, reset to remote truth, then merge your local content in
3. commit + push (retried automatically if another machine pushed first)
4. copy the merged result back into place locally
Result: open a project — or edit your global config — anywhere, and it's there and up to date, both ways.
```

### Per-project memory

Memory lives at `~/.claude/projects/<project>/memory/*.md`. Notes are keyed by a **stable identity** — the
normalized **git remote URL**, falling back to the folder name — not the machine-specific path slug, so the
same project's notes follow it whether it lives at `D:\...\proj` on Windows or `/home/you/proj` on Linux.

**Merge rules (all lossless).** A note on only one side is copied to the other. For a note on both sides,
the sync does a **3-way merge** against the version this machine last synced (the base): if only one side
changed, that edit wins with **no conflict** — simply editing a note is never treated as a conflict. Only
when **both** sides changed the same note since the last sync are both copies kept (`<name>.md` +
`<name>.conflict.md`, compared ignoring CRLF/LF so line-endings alone never trigger it). `MEMORY.md` (the
index) is line-unioned.

**Deletions are treated by kind.** A plain `rm` of a **real note** does **not** propagate — it reappears
from the other machine, so an accidental delete is never silently mirrored everywhere. To remove a real
note **on purpose** (from the backup and every machine), use **`/memory delete <note>`**: it drops a
`<name>.md.deleted` tombstone the hook honors everywhere. A **`.conflict.md`** is an ephemeral marker, not a
note: once you reconcile it into `<name>.md` and delete it, that removal **also** propagates (via a
`<name>.conflict.md.deleted` tombstone), so conflict files never pile up. (To bring a deleted note back,
remove its tombstone from `memory/<safeKey>/` in the backup.)

### Global config & system agent skills

Beyond per-project memory, the same hook continuously syncs your **user-level config** — `CLAUDE.md`,
`keybindings.json`, `settings.json`, `plugins.json`, and your `commands/`, `skills/` and `agents/` folders —
with the identical 3-way, conflict-safe logic. Edit your global `CLAUDE.md` on one machine and it reaches
the others automatically.

**System-level agent skills** installed outside Claude Code (e.g. by [skill.sh](https://skill.sh) into
`~/.agents/skills/`, a cross-tool skills home separate from Claude Code's own `~/.claude/skills`) ride along
the same way — mirrored under `agents-skills/` in the backup, together with the portable `.skill-lock.json`
install manifest (GitHub source URLs + hashes, no absolute paths). This is **skipped entirely** on machines
without `~/.agents`, so it's a no-op if you don't use that ecosystem.

**VSCode profile (opt-in, off by default).** Run `/config vscode on` and the hook also syncs your VSCode
*User* profile — `settings.json`, `keybindings.json`, `tasks.json`, `snippets/`, and a portable
**extensions list** (`code --list-extensions`, reinstalled by `/import` via `code --install-extension`) —
under `vscode/` in the backup, with the same 3-way merge. The machine-specific `globalStorage/`,
`workspaceStorage/`, `History/` and `sync/` folders are **never** touched. Toggle it per machine with
`/config`; it's a no-op where VSCode isn't installed.

It's a **strict allowlist**: nothing else is ever touched, and anything machine-specific belongs in
`settings.local.json` (never synced — nor are `.credentials.json`, history, or tokens). A genuine two-sided
edit of the same config file keeps your local copy and saves the other version as a `.cc-conflict` sidecar.

### Credentials & safety

Each machine needs `git` plus a git credential for `github.com` that the OS credential helper already holds
(git-credential-manager on Windows, `osxkeychain` on macOS, libsecret/store on Linux, or `gh auth login`).
**The hook needs no personal access token** — it pushes with git's normal credentials (the same ones that
let you `git push`), so nothing expires out from under it in an env var. It runs headless with
`GIT_TERMINAL_PROMPT=0`, so a missing credential fails fast instead of hanging. The hook is **fail-open**:
if anything is missing or a push can't complete, your local files are left untouched, it tells you why, and
it retries next session. The `SessionEnd` sync runs **detached** so closing Claude Code never cancels a
mid-flight push (and `SessionStart` re-syncs regardless, so nothing is lost either way).

---

## Commands

| Command | One-liner |
|---|---|
| `/setup` | First-time setup — sign in with the GitHub CLI and prepare your backup repo |
| `/export` | Upload a full snapshot of your configuration to GitHub |
| `/import` | Restore your configuration from GitHub (e.g. on a new machine) |
| `/status` | Show local status and last-backup info |
| `/memory` | List / view / delete synced memory notes without opening GitHub |
| `/sessions` | Manage a project's chat sessions — list / delete / clean / rename (also `all` projects) |
| `/config` | Plugin options — e.g. turn on the opt-in **VSCode profile sync** |
| `/uninstall` | Remove the plugin's local files (your backup and `gh` login stay intact) |

### `/setup`

Run **once per machine**, first thing after installing. It:

- **Installs the GitHub CLI (`gh`) if it's missing** — winget on Windows, Homebrew on macOS, the distro
  package manager on Linux.
- **Signs you in** via a one-line `gh auth login` (browser or device-code OAuth, requesting the `repo`
  scope) if you aren't already, and runs `gh auth setup-git` so `git` (and the sync hook) use that
  credential — kept in your OS credential store, **never** by this plugin.
- **Ensures your private `claude-code-config` repo exists**, and records only its (non-secret) URL to
  `~/.config/cc-cnf-sync/repo`.

No restart needed — there's no MCP to reconnect.

### `/export`

Uploads a **complete snapshot** of your config to the backup repo in **one additive git commit** (no
per-file API calls; scales to large memory trees). It includes everything in the *What gets backed up* table:
config files, the `commands`/`skills`/`agents` trees, your **system agent skills** (`~/.agents/skills` +
lock), a **portable `plugins.json`** manifest, and **all** per-project memory. It's **additive** — files
already in the repo that this machine didn't regenerate (other machines' memory, a project's previous name)
are preserved, never deleted. Secrets and session transcripts are excluded.

Because the hook already keeps memory + config in continuous sync, `/export` is mainly for your **first**
backup or an explicit full snapshot; day-to-day you don't need to run it.

### `/import`

Restores your setup from the backup — typically on a **new machine**. It clones the backup, shows its
metadata (date, machine, version) and **asks for confirmation**, then:

- Makes a **safety backup** first — `~/.claude-before-restore-<timestamp>` (and `~/.agents-before-restore-…`
  if present) — so you can always roll back.
- Restores the config files, the `commands`/`skills`/`agents` trees, and your **system agent skills** into
  `~/.agents/skills`.
- **Rebuilds plugins** from the portable `plugins.json` — re-adds each marketplace and installs each plugin
  with the Claude Code CLI, regenerating the correct local paths for *this* machine.
- Re-seats **per-project memory** onto this machine's projects (and the hook re-attaches the rest by
  git-remote key as you open each project).

Restart Claude Code afterward so rebuilt plugins finish loading.

### `/status`

Shows a quick health check without cloning anything:

- **Local:** Claude Code version, installed plugins, and GitHub CLI auth state.
- **Last backup (read from GitHub):** date, machine, Claude version, memory note count, and system
  agent-skill count.
- **Days since last backup**, with a reminder if it's been more than 7 days.

### `/memory`

Inspect and manage your synced memory **without opening GitHub**: **list** all notes for the current
project, **view** a note's contents, or **delete** one. Deleting through `/memory` is the *intentional*
delete — it drops a tombstone so the removal propagates to your backup and every machine (a plain `rm`,
by contrast, reappears from another machine on the next sync).

### `/uninstall`

Guided removal of the plugin's **local** files (its cache clone, the `~/.config/cc-cnf-sync` pointer, and
per-machine hook state). Your **GitHub backup** (`claude-code-config`) and your **`gh` login** are left
completely untouched, so reinstalling + `/import` brings everything back.

---

## Requirements

- Claude Code v22+
- Git Bash on Windows (Claude Code already requires it) — no extra setup on Linux/macOS
- The **GitHub CLI (`gh`)** — `/setup` uses it to sign in (it requests the `repo` scope). You don't need to
  install it yourself: **`/setup` installs `gh` automatically if it's missing** (winget on Windows, Homebrew
  on macOS, the distro package manager on Linux). Manual install: https://github.com/cli/cli#installation
- For the continuous sync hook: `git` on `PATH` (on Windows, Git Bash — bundled with Git). It authenticates
  through the same `gh` login `/setup` sets up (`gh auth setup-git`), so there's nothing extra to configure.
  If `git`/auth is missing, the hook simply does nothing; the rest of the plugin still works.

## Quick start

```
claude plugin install cc-cnf-sync@jeg
```

Restart Claude Code, then run:

```
/setup
```

That's it — from then on the hook keeps memory + config in sync automatically. Run `/export` once to seed
your first full snapshot, and `/import` on any new machine.

## Uninstall

Run the guided command, which removes the plugin's local files (your GitHub backup and your `gh` login are
left untouched):

```
/uninstall
```

Or remove just the plugin manually:

```
claude plugin uninstall cc-cnf-sync@jeg
```

Your backups on GitHub (the `claude-code-config` repo) are not affected either way.

## License

This plugin is licensed under the [MIT License](LICENSE).
