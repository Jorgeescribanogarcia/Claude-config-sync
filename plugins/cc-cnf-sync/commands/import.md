# /import

Restore your configuration from GitHub. Works on **Linux, macOS and Windows** (Git Bash).
Uses the **GitHub CLI (`gh`) + `git`** — one clone, no per-file API calls.

## Steps to follow

### STEP 1 — Verify GitHub CLI session

```bash
gh auth status --hostname github.com 2>&1 | head -5
```

**If it is not installed or not authenticated**, stop and show:
```
❌ Not signed in to GitHub.

Run /setup first (it installs/authenticates the GitHub CLI),
then run /import again.
```

**If authenticated**, capture the username with `gh api user --jq .login` and continue.

---

### STEP 2 — Check the backup repository exists

```bash
gh repo view "<username>/claude-code-config" >/dev/null 2>&1 && echo EXISTS || echo MISSING
```

**If MISSING**, stop and show:
```
❌ Backup repository not found.

You haven't created a backup yet. Run /export first.
```

**If EXISTS**, continue.

---

### STEP 3 — Clone the backup and show its info

Clone the whole backup once (everything restores from this local copy):

```bash
TS=$(date +%Y%m%d-%H%M%S)
CLONE="${TMPDIR:-/tmp}/cc-cnf-sync-restore-$TS"
gh repo clone "<username>/claude-code-config" "$CLONE" -- --depth 1 \
  || { echo "clone failed"; exit 1; }
cat "$CLONE/backup-meta.json" 2>/dev/null || echo "(no backup-meta.json)"
echo "$CLONE"
```

Read `backup-meta.json` from the clone and show, then **wait for confirmation**:
```
📦 Backup found

  📅 Backup date: <backup_date>
  🖥️  Machine: <hostname>
  🔖 Claude Code version: <claude_version>
  🔗 Repository: https://github.com/<username>/claude-code-config

⚠️  This will overwrite your current configuration at:
    ~/.claude/
    ~/.agents/skills/   (system agent skills — only if the backup has them)
    VSCode profile       (settings/keybindings/snippets + extensions — only if the backup has it)

Continue with restore? (reply: yes / no)
```

If the user replies anything other than affirmative, stop.

---

### STEP 4 — Create a local safety backup

Before overwriting anything, back up the current config:

```bash
SAFETY_BACKUP="$HOME/.claude-before-restore-$TS"
cp -r "$HOME/.claude" "$SAFETY_BACKUP"
# Also snapshot ~/.agents (system agent skills) if present — the restore may overwrite ~/.agents/skills.
[ -d "$HOME/.agents" ] && cp -r "$HOME/.agents" "$HOME/.agents-before-restore-$TS"
# And the VSCode User profile if a vscode/ backup will overwrite it.
if [ -d "$CLONE/vscode" ]; then
  case "$(uname -s)" in Darwin) V="$HOME/Library/Application Support/Code/User";; *MINGW*|*MSYS*|*CYGWIN*) V="$APPDATA/Code/User";; *) V="$HOME/.config/Code/User";; esac
  [ -d "$V" ] && cp -r "$V" "$HOME/.vscode-user-before-restore-$TS"
fi
echo "Safety backup created at: $SAFETY_BACKUP"
```

Show:
```
🛡️  Safety backup created at:
    ~/.claude-before-restore-<timestamp>
    ~/.agents-before-restore-<timestamp>   (only if ~/.agents existed)
    (in case you need to roll back)
```

---

### STEP 5 — Restore the plain config files from the clone

Copy the backed-up config files out of `$CLONE` into `~/.claude/`. **Skip** control files that are
handled separately or must never be restored:
`backup-meta.json`, `plugins.json`, `memory-manifest.json`, the whole `memory/` tree (STEP 6b),
`.git/`, and any legacy `installed_plugins.json` / `known_marketplaces.json` (machine-specific
absolute paths — the portable `plugins.json` in STEP 6 rebuilds plugins for *this* machine).

```bash
DEST="$HOME/.claude"
mkdir -p "$DEST"
for f in settings.json CLAUDE.md keybindings.json; do
  [ -f "$CLONE/$f" ] && cp "$CLONE/$f" "$DEST/$f" && echo "restored $f"
done
for d in commands skills agents; do
  [ -d "$CLONE/$d" ] && { mkdir -p "$DEST/$d"; cp -R "$CLONE/$d/." "$DEST/$d/"; echo "restored $d/"; }
done

# System-level agent skills → ~/.agents/skills (+ the portable install lock). Only if the backup has them.
if [ -d "$CLONE/agents-skills" ]; then
  mkdir -p "$HOME/.agents/skills"
  cp -R "$CLONE/agents-skills/." "$HOME/.agents/skills/"
  [ -f "$CLONE/agents-skill-lock.json" ] && cp "$CLONE/agents-skill-lock.json" "$HOME/.agents/.skill-lock.json"
  echo "restored agents-skills/ (→ ~/.agents/skills)"
fi
```

Show progress as each file/dir is restored.

---

### STEP 5c — Restore the VSCode profile (only if the backup has one)

If `$CLONE/vscode/` exists, the backup includes a VSCode profile (opt-in `/config vscode on`).
Restore the user config + snippets, and reinstall the extensions from the portable list:

```bash
if [ -d "$CLONE/vscode" ]; then
  case "$(uname -s)" in
    Darwin)                  VSC="$HOME/Library/Application Support/Code/User" ;;
    *MINGW*|*MSYS*|*CYGWIN*)  VSC="$APPDATA/Code/User" ;;
    *)                       VSC="$HOME/.config/Code/User" ;;
  esac
  mkdir -p "$VSC/snippets"
  for f in settings.json keybindings.json tasks.json locale.json argv.json; do
    [ -f "$CLONE/vscode/$f" ] && cp "$CLONE/vscode/$f" "$VSC/$f" && echo "restored vscode/$f"
  done
  [ -d "$CLONE/vscode/snippets" ] && cp -R "$CLONE/vscode/snippets/." "$VSC/snippets/" && echo "restored vscode/snippets/"
  # reinstall extensions from the portable list (needs the `code` CLI on PATH)
  if [ -f "$CLONE/vscode/extensions.txt" ] && command -v code >/dev/null 2>&1; then
    while IFS= read -r ext; do
      [ -n "$ext" ] && code --install-extension "$ext" --force >/dev/null 2>&1 && echo "  + $ext"
    done < "$CLONE/vscode/extensions.txt"
  elif [ -f "$CLONE/vscode/extensions.txt" ]; then
    echo "  (VSCode 'code' CLI not on PATH — install extensions later: cat $CLONE/vscode/extensions.txt)"
  fi
fi
```

The machine-specific `globalStorage/`, `workspaceStorage/`, `History/` and `sync/` folders are never
part of the backup, so they are untouched here.

---

### STEP 6 — Rebuild plugins from the portable manifest

If `$CLONE/plugins.json` exists, use it to re-add marketplaces and reinstall plugins via the
Claude Code CLI — this regenerates the correct local paths and cache for **this** machine.

1. Read `$CLONE/plugins.json`.
2. **First** add every marketplace (idempotent — ignore "already exists" errors), then install
   every plugin (you are the agent — iterate over the manifest yourself; no shell JSON parsing):

```bash
# For each marketplace with a non-empty "add":
claude plugin marketplace add "<add>" --scope user

# Then, for each plugin:
claude plugin install "<id>" --scope user
# If that plugin had "enabled": false at backup time, also run:
claude plugin disable "<id>"
```

If `plugins.json` is **absent** (legacy backup), tell the user their backup predates portable
plugin sync; they should run `/export` again after restoring, then reinstall plugins manually with
`claude plugin install <name>@<marketplace>`.

---

### STEP 6b — Restore per-project memory (same-machine)

This re-seats memory onto **this** machine's project slugs. Cross-machine / cross-OS attach is
handled automatically by the `SessionStart` hook — you don't need to do anything for that.

If `$CLONE/memory-manifest.json` exists, map each backed-up project's `safeKey` to its original
`slug` and copy the notes into place:

```bash
# $slug/$safeKey come from a schema-2 manifest entry { "slug": "...", "safeKey": "...", ... }.
SRC="$CLONE/memory/$safeKey"
DST="$HOME/.claude/projects/$slug/memory"
if [ -d "$SRC" ]; then
  mkdir -p "$DST"
  # Copy notes only — never the per-machine state files.
  cp "$SRC"/*.md "$DST"/ 2>/dev/null
  echo "restored memory for $slug"
fi
```

Iterate over the manifest entries yourself. If the manifest is **schema 1** (legacy:
`memory/<slug>/...`, no `safeKey`), fall back to using the `slug` as the folder name. If no
`memory-manifest.json` exists at all, skip this step silently.

> **The hook is what makes memory portable across machines/OS.** Even if this same-machine step maps
> nothing (e.g. restoring on a brand-new box where the slugs differ), the `SessionStart` hook
> re-attaches each project's memory by its git-remote key the moment you open it — pulling from your
> backup automatically. It needs `git` and a gh-authenticated github.com (done by /setup) — **no
> personal access token**; it authenticates the same way `git push` does.
>
> This overwrites memory only for projects present in the backup; others are left untouched, and the
> STEP 4 safety backup preserves the old `.claude` for rollback.

---

### STEP 7 — Final summary

```
✅ Restore completed

📁 Files restored: <count>
🔌 Plugins rebuilt: <n> plugin(s) from <m> marketplace(s)
🧠 Memory restored: <k> note(s) across <n> project(s)
🆚 VSCode profile: <restored + N extensions | not in backup>
📅 Backup applied: <backup_date>

⚠️  Restart Claude Code to apply all changes (plugins finish loading on restart).

🛡️  If something looks wrong, your previous config is at:
    ~/.claude-before-restore-<timestamp>
```
