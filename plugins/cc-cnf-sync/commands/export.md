# /export

Upload your configuration to GitHub. Works on **Linux, macOS and Windows** (Git Bash).

## Steps to follow

### STEP 1 — Verify GitHub CLI session

This command uploads via the **GitHub CLI (`gh`) + `git`** — no MCP, no per-file API calls.
Confirm `gh` is installed and authenticated:

```bash
gh auth status --hostname github.com 2>&1 | head -5
```

**If it is not installed or not authenticated** (non-zero exit / "not logged in" / "token
invalid"), stop and show:
```
❌ Not signed in to GitHub.

Run /setup first (it installs/authenticates the GitHub CLI),
then run /export again.
```

**If authenticated**, capture the username:
```bash
gh api user --jq .login
```
Save it as `<username>` and continue.

---

### STEP 2 — Check or create the backup repository

```bash
gh repo view "<username>/claude-code-config" >/dev/null 2>&1 \
  && echo EXISTS \
  || gh repo create "<username>/claude-code-config" --private --add-readme \
       --description "Automated backup and restore of Claude Code configuration files (settings, plugins, commands, skills, agents) synced to a private GitHub repository." \
     && echo CREATED
```
`--add-readme` gives a new repo an initial commit so the clone+push in STEP 5 never trips on an
unborn branch.

Show:
```
✅ GitHub CLI authenticated as @<username>
✅ Repository: github.com/<username>/claude-code-config
```

---

### STEP 3 — Collect configuration files

Run the following `bash` to collect all config files into a temp directory. This works
on Linux, macOS and Windows (Git Bash), where `~/.claude` maps to the right place:

```bash
TS=$(date +%Y%m%d-%H%M%S)
TEMP_DIR="${TMPDIR:-/tmp}/claude-config-backup-$TS"
mkdir -p "$TEMP_DIR"

SOURCE="$HOME/.claude"

for f in settings.json CLAUDE.md keybindings.json; do
  [ -f "$SOURCE/$f" ] && cp "$SOURCE/$f" "$TEMP_DIR/$f"
done

for d in commands skills agents; do
  [ -d "$SOURCE/$d" ] && cp -r "$SOURCE/$d" "$TEMP_DIR/$d"
done

# System-level agent skills (skill.sh & co.) live OUTSIDE ~/.claude, at ~/.agents/skills — a
# cross-tool skills home, distinct from Claude Code's own ~/.claude/skills. Back them up under
# `agents-skills/` (+ the portable install lock `.skill-lock.json`, which has no absolute paths).
# Skipped entirely if ~/.agents is absent (users without that ecosystem).
if [ -d "$HOME/.agents/skills" ]; then
  cp -r "$HOME/.agents/skills" "$TEMP_DIR/agents-skills"
  [ -f "$HOME/.agents/.skill-lock.json" ] && cp "$HOME/.agents/.skill-lock.json" "$TEMP_DIR/agents-skill-lock.json"
fi

# VSCode profile — ONLY when opted in (`/config vscode on`). Same allowlist as the hook: user config
# files + snippets/ + a portable extensions list. globalStorage/workspaceStorage/History/sync excluded.
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/cc-cnf-sync/config"
if [ -f "$CFG" ] && grep -q '^vscode_sync=on' "$CFG"; then
  case "$(uname -s)" in Darwin) VSC="$HOME/Library/Application Support/Code/User";; *MINGW*|*MSYS*|*CYGWIN*) VSC="$APPDATA/Code/User";; *) VSC="$HOME/.config/Code/User";; esac
  if [ -d "$VSC" ]; then
    mkdir -p "$TEMP_DIR/vscode/snippets"
    for f in settings.json keybindings.json tasks.json locale.json argv.json; do [ -f "$VSC/$f" ] && cp "$VSC/$f" "$TEMP_DIR/vscode/$f"; done
    [ -d "$VSC/snippets" ] && cp -r "$VSC/snippets/." "$TEMP_DIR/vscode/snippets/"
    command -v code >/dev/null 2>&1 && code --list-extensions 2>/dev/null | sort > "$TEMP_DIR/vscode/extensions.txt"
  fi
fi

echo "$TEMP_DIR"
```

**IMPORTANT — Never include these files:**
- `.credentials.json`
- `settings.local.json`
- `history.jsonl`
- `~/.claude.json`
- Any file containing "token", "secret", or "key" in its name
- `plugins/installed_plugins.json` and `plugins/known_marketplaces.json` — these contain
  **absolute, machine-specific paths** (e.g. `/home/<you>/.claude/plugins/cache/...` or
  `C:\Users\<you>\.claude\plugins\cache\...`) and a local `cache/` that does not exist on
  other machines. They are intentionally replaced by the portable manifest generated in the
  next step.
- Session transcripts — `projects/<slug>/*.jsonl` (and any other files directly under a project
  dir). These are large and may contain secrets pasted into the chat. Only each project's
  `memory/` subfolder is backed up (STEP 3c), never the raw sessions.

---

### STEP 3b — Generate a portable plugin manifest

Instead of copying the machine-specific plugin JSONs, distill a portable manifest from the
Claude Code CLI. It records only *what* is installed and *which marketplace* it came from —
no absolute paths, no local cache dirs — so `/import` can rebuild it on any machine/OS.

Run these two commands and read their JSON output:

```bash
claude plugin marketplace list --json
claude plugin list --json
```

Then **build `plugins.json` yourself** (you are the agent — construct the JSON directly from
the command output; do not rely on `jq`/`python` being installed) and write it to
`$TEMP_DIR/plugins.json` with this schema:

- `marketplaces[]`: one entry per marketplace with `name`, `source`, and `add`, where `add`
  is the source string that `claude plugin marketplace add` accepts:
  - github source → `"owner/repo"` (from the marketplace's `repo` field)
  - git source → the full clone URL (from the marketplace's `url` field)
- `plugins[]`: one entry per installed plugin with `id`, `scope`, and `enabled`.

The resulting `plugins.json` looks like:
```json
{
  "schema": 1,
  "marketplaces": [
    { "name": "claude-plugins-official", "source": "github", "add": "anthropics/claude-plugins-official" },
    { "name": "jeg", "source": "git", "add": "https://github.com/Jorgeescribanogarcia/jeg-cc-marketplace.git" }
  ],
  "plugins": [
    { "id": "cc-cnf-sync@jeg", "scope": "user", "enabled": true }
  ]
}
```

Upload `plugins.json` to the repo root alongside the other files.

---

### STEP 3c — Collect per-project memory (keyed by a portable, OS-independent identity)

Persistent memory is **per project**: it lives at `~/.claude/projects/<slug>/memory/*.md`, where
`<slug>` is the project's absolute path with separators replaced. That slug is path- and OS-specific
(Windows `D--...-marketplace` ≠ Linux `-home-jorge-marketplace`), so keying by slug alone can't
follow the project to another machine. Instead we key each project's memory by a **stable identity**:
the normalized **git remote URL** (identical on every clone/OS), falling back to the folder name.

The `SessionStart`/`SessionEnd` hook (`hooks/sync-memory.sh`) recomputes this same key on every machine
and **bidirectionally syncs** the memory (pull + merge + push) automatically, so this `/export` is just a
full manual snapshot on top of the same layout. Run this `bash` (works on Linux, macOS and Windows via
Git Bash); the key rules **must stay identical** to `norm_key()` in `hooks/sync-memory.sh`:

> **Before running the script**, fetch the repo's current `memory-manifest.json` to
> `$TEMP_DIR/prev-manifest.json` if it exists — it lets this backup detect a changed key (e.g.
> the repo was renamed) and leave a rename alias so old clones keep resolving, and it powers the
> additive manifest merge:
>
> ```bash
> gh api "repos/<username>/claude-code-config/contents/memory-manifest.json" \
>   -H "Accept: application/vnd.github.raw" > "$TEMP_DIR/prev-manifest.json" 2>/dev/null \
>   || rm -f "$TEMP_DIR/prev-manifest.json"   # absent on the first backup — the script handles that
> ```

```bash
SOURCE_PROJECTS="$HOME/.claude/projects"
MEM_DEST="$TEMP_DIR/memory"

# Normalize a git remote (or folder name) into an OS-independent key.
# MUST stay identical to norm_key() in hooks/sync-memory.sh.
# Input is read from $nk_arg, NOT a positional $1: Claude Code substitutes $1/$0/… inside a
# slash command's bash with empty strings, so `k=$1` would silently become `k=` at runtime
# (→ empty keys → every project mis-keyed). $nk_arg is a plain variable, immune to that.
norm_key() {
  k=$nk_arg
  case "$k" in *.git) k=${k%.git} ;; esac
  case "$k" in *@*:*) host=${k#*@}; host=${host%%:*}; path=${k#*:}; k="$host/$path" ;; esac
  k=$(printf '%s' "$k" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]*@##')
  printf '%s' "$k" | tr 'A-Z' 'a-z'
}

# Accumulate manifest entries in files (not a shell var): the additive-merge step below
# reads prev entries in a pipe subshell, which can't append to a variable.
ENTRIES_FILE="$TEMP_DIR/.mani-entries"   # one JSON object per line
SAFES_FILE="$TEMP_DIR/.mani-safes"       # safeKeys generated this run (for the union merge)
: > "$ENTRIES_FILE"; : > "$SAFES_FILE"
count=0
if [ -d "$SOURCE_PROJECTS" ]; then
  for pdir in "$SOURCE_PROJECTS"/*/; do
    mdir="${pdir}memory"
    [ -d "$mdir" ] || continue
    [ -n "$(find "$mdir" -type f 2>/dev/null | head -n1)" ] || continue
    fcount=$(find "$mdir" -type f 2>/dev/null | wc -l | tr -d ' ')
    slug=$(basename "$pdir")

    # Recover the project's real cwd from ANY session transcript (the slug can't be reversed
    # reliably, and the first .jsonl may be a summary sidecar with no cwd — so scan them all).
    # Use grep (not sed): a `sed -n 's/..."cwd"...\1/p'` over the .jsonl aborts with
    # "unterminated `s' command" under Git Bash, silently emptying cwd → keys fall back to
    # `slug/...` and create duplicate memory folders. grep|cut is robust everywhere.
    cwd=$(grep -ho '"cwd"[ ]*:[ ]*"[^"]*"' "$pdir"*.jsonl 2>/dev/null | head -1 | cut -d'"' -f4)
    # Normalize a Windows cwd (JSON-escaped `C:\\Users\\...`) to forward slashes. Plain
    # `tr '\\' '/'` collapses the escaped `\\` into `//`; squash runs of slashes back to one.
    cwd=$(printf '%s' "$cwd" | tr '\\' '/' | sed 's#//*#/#g')

    key=""
    if [ -n "$cwd" ]; then
      remote=$(git -C "$cwd" remote get-url origin 2>/dev/null)
      if [ -n "$remote" ]; then
        nk_arg="$remote"; key=$(norm_key)
      else
        key="local/$(basename "$cwd" | tr 'A-Z' 'a-z')"
      fi
    fi
    [ -n "$key" ] || key="slug/$(printf '%s' "$slug" | tr 'A-Z' 'a-z')"   # last resort
    safe=$(printf '%s' "$key" | sed 's/[^a-z0-9._-]/-/g')
    if [ -n "$cwd" ]; then name=$(basename "$cwd"); else name=$slug; fi

    mkdir -p "$MEM_DEST/$safe"
    cp -r "$mdir/." "$MEM_DEST/$safe/" 2>/dev/null
    # NEVER back up the hook's per-machine state (.cc-cnf-sync-base, -conflicts, -checked):
    # those are local-only 3-way bases; uploading them corrupts the merge on other machines.
    rm -f "$MEM_DEST/$safe"/.cc-cnf-sync-* 2>/dev/null

    # Rename-robustness: if a previous backup keyed THIS project (matched by slug — stable on
    # the same machine) under a DIFFERENT safeKey, the repo was likely renamed. Drop a sidecar
    # `memory/<oldSafeKey>.alias` (one line = the current safeKey) so a clone that still computes
    # the old key keeps resolving to the up-to-date notes. Read by norm_key()'s companion logic
    # in hooks/sync-memory.sh. (grep|cut, not sed -n 's/…/p' — that aborts under Git Bash.)
    if [ -f "$TEMP_DIR/prev-manifest.json" ]; then
      prevsafe=$(grep -F "\"slug\": \"$slug\"" "$TEMP_DIR/prev-manifest.json" 2>/dev/null \
                 | grep -o '"safeKey"[ ]*:[ ]*"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -n "$prevsafe" ] && [ "$prevsafe" != "$safe" ]; then
        printf '%s\n' "$safe" > "$MEM_DEST/$prevsafe.alias"
      fi
    fi

    printf '    { "slug": "%s", "key": "%s", "safeKey": "%s", "name": "%s", "files": %s }\n' \
      "$slug" "$key" "$safe" "$name" "$fcount" >> "$ENTRIES_FILE"
    printf '%s\n' "$safe" >> "$SAFES_FILE"
    count=$((count+1))
  done
fi

# ADDITIVE merge (union by safeKey): carry over every project the repo's previous manifest
# had that THIS machine doesn't (other machines' projects, or a project's previous name).
# Regenerating from only the local machine would silently PRUNE foreign projects from the
# inventory even though their memory/ folders survive — the manifest must be a union.
carried=0
if [ -f "$TEMP_DIR/prev-manifest.json" ]; then
  grep -o '{[^{}]*}' "$TEMP_DIR/prev-manifest.json" 2>/dev/null | while IFS= read -r obj; do
    psafe=$(printf '%s' "$obj" | grep -o '"safeKey"[ ]*:[ ]*"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$psafe" ] || continue
    grep -qxF "$psafe" "$SAFES_FILE" 2>/dev/null && continue   # already regenerated this run
    printf '    %s\n' "$obj" >> "$ENTRIES_FILE"
    printf '%s\n' "$psafe" >> "$SAFES_FILE"                    # guard against dups within prev
  done
  total=$(wc -l < "$SAFES_FILE" 2>/dev/null | tr -d ' '); [ -n "$total" ] || total=0
  carried=$((total - count))
fi

# Join the per-line JSON objects into the manifest array: append a comma to every line except
# the last. Done with sed, NOT `awk '{print $0}'` — Claude Code's slash-command substitution
# would replace awk's $0 with empty at runtime, emitting nothing. (`$!`/`$` here are sed
# addresses/anchors, not positional params, so they survive.) $(...) strips the trailing
# newline, so the closing `]` gets its own \n from the format string.
body=$(sed '$!s/$/,/' "$ENTRIES_FILE")
printf '{\n  "schema": 2,\n  "projects": [\n%s\n  ]\n}\n' "$body" > "$TEMP_DIR/memory-manifest.json"
rm -f "$ENTRIES_FILE" "$SAFES_FILE"
echo "Memory: $count project(s) from this machine, $carried carried from other machines."
```

This writes each project's notes to `memory/<safeKey>/...` in the temp dir plus a
`memory-manifest.json` at the root, e.g.:
```json
{
  "schema": 2,
  "projects": [
    {
      "slug": "D--Windows-Usuarios-Elmister180-Escritorio-jeg-agents-marketplace",
      "key": "github.com/jorgeescribanogarcia/jeg-agents-marketplace",
      "safeKey": "github.com-jorgeescribanogarcia-jeg-agents-marketplace",
      "name": "jeg-agents-marketplace",
      "files": 3
    }
  ]
}
```

Upload the `memory/` tree (including any `<oldSafeKey>.alias` sidecars) and `memory-manifest.json`
to the repo alongside the other files. The upload is **additive** — do NOT delete `memory/` folders
that exist in the repo but not in this backup: they belong to other machines' projects or to a
project's previous name, and pruning them would break those clones.

> **Portability:** because memory is keyed by the git remote (not the path), the `SessionStart` hook
> can re-attach it on any machine/OS where the same repo is checked out — regardless of where it lives
> on disk. Projects with no git remote fall back to a folder-name key (works if the folder name matches).
>
> **Repo renames:** renaming a repo changes its normalized key, so a fresh clone would compute a new
> key with no folder. To survive that, a backup that detects a project's key changed (same slug, new
> safeKey) writes a `memory/<oldSafeKey>.alias` sidecar pointing at the current key; the hook follows
> it, so clones on either the old or new remote keep resolving to the same, up-to-date notes.

---

### STEP 4 — Add metadata file

Create a file called `backup-meta.json` in the temp directory. Fill the fields from these
commands: `claude --version`, `uname -s` (OS, prints "Windows" if it fails), and `hostname`.

```json
{
  "backup_date": "<ISO timestamp>",
  "claude_version": "<output of: claude --version>",
  "os": "<Linux | Darwin | Windows>",
  "hostname": "<output of: hostname>"
}
```

---

### STEP 5 — Upload to GitHub (git clone + commit + push)

Upload everything in **one additive commit** via `git` — no per-file API calls, and it scales to
large memory trees. `gh repo clone` reuses your gh authentication; the copy is **additive**, so
files already in the repo that this backup didn't regenerate (other machines' memory, a project's
previous name, etc.) are preserved.

```bash
CLONE="$TEMP_DIR-clone"   # derived from $TEMP_DIR (which you already have) — no $TS dependency
gh repo clone "<username>/claude-code-config" "$CLONE" -- --depth 1 \
  || { echo "clone failed — is /setup done and gh authenticated?"; exit 1; }

# Copy the snapshot over the clone. Additive by construction: $TEMP_DIR has no .git (the clone's
# own .git stays intact) and existing repo files not present in $TEMP_DIR are left untouched.
cp -R "$TEMP_DIR"/. "$CLONE"/

cd "$CLONE"
git add -A
if git diff --cached --quiet; then
  echo "Nothing changed — backup already up to date."
else
  git -c user.name="cc-cnf-sync" -c user.email="export@$(hostname)" \
      commit -q -m "backup: $(date +%Y-%m-%d) - Claude Code config sync"
  git push origin HEAD && echo "Pushed."
fi
```

`gh repo clone "<user>/repo" DIR -- --depth 1` passes `--depth 1` through to `git clone`; the push
authenticates through gh (wired by `gh auth setup-git` in /setup). The upload is additive — it
never deletes `memory/` folders the repo already has (see STEP 3c).

---

### STEP 6 — Final summary

```
✅ Backup completed

📦 Files uploaded: <count>
🔗 Repository: https://github.com/<username>/claude-code-config
📅 Date: <timestamp>

Included:
  ✓ settings.json
  ✓ CLAUDE.md
  ✓ plugins.json (portable manifest — <n> plugins, <m> marketplaces)
  ✓ memory/ (<n> project(s), <k> notes)
  ✓ commands/ (<n> files)
  ✓ skills/ (<n> files)
  ✓ agents/ (<n> files)
  ✓ agents-skills/ (<n> files)   ← system agent skills (~/.agents/skills); omit if ~/.agents is absent
  ✓ vscode/ (<n> files, <k> extensions)   ← only if VSCode sync is on (/config); omit otherwise
  ✓ memory/ (<n> project(s))   ← only if the user opted in; omit this line otherwise

Excluded for security:
  ⊘ .credentials.json
  ⊘ settings.local.json
  ⊘ history.jsonl
  ⊘ session transcripts (projects/*.jsonl)
```
