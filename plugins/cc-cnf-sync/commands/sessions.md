# /sessions

Manage a project's accumulated chat **sessions** — list, delete, clean, or rename them — without
leaving Claude Code. Sessions are the raw transcripts at `~/.claude/projects/<slug>/*.jsonl`; they are
**not** part of the backup (cc-cnf-sync never uploads them), they just pile up and take disk space.

The text after `/sessions` (`$ARGUMENTS`) selects the action:

- `/sessions`  or  `/sessions list`        → list this project's sessions
- `/sessions delete <n>`                    → delete session #n (asks first)
- `/sessions clean [keep <N>]`              → keep the N most recent, delete the rest (default N=5; asks first)
- `/sessions rename <n> <new title>`        → give session #n a custom title
- `/sessions all`                           → list sessions across **every** project (accepts `delete`/`clean` too)

Works on **Linux, macOS and Windows** (Git Bash). `<n>` is the index shown by `list`.

---

## Locate this project's session directory

The current project's session dir is the one under `~/.claude/projects/` whose transcripts were
recorded with `cwd` == the current working directory. **Read `.jsonl` with `grep | cut`, never
`sed -n 's/…/p'`** (that aborts in Git Bash).

```bash
norm_path() { printf '%s' "$1" | tr '\\' '/' | tr 'A-Z' 'a-z' | sed 's#//*#/#g; s#^\([a-z]\):#/\1#'; }
HERE=$(norm_path "$PWD")
PDIR=""
for d in "$HOME/.claude/projects"/*/; do
  cwd=$(grep -oh '"cwd":"[^"]*"' "$d"*.jsonl 2>/dev/null | head -1 | cut -d'"' -f4)
  [ -n "$cwd" ] || continue
  [ "$(norm_path "$cwd")" = "$HERE" ] && { PDIR="$d"; break; }
done
[ -n "$PDIR" ] || echo "NO_PROJECT_DIR"
```

If it prints `NO_PROJECT_DIR`, tell the user no session folder matches this project and stop.

## A reusable "list the sessions in a dir" helper

Given a project dir in `$1`, print its sessions newest-first with an index:

```bash
list_dir() {  # $1 = project dir
  i=0
  for s in $(ls -t "$1"*.jsonl 2>/dev/null); do
    i=$((i+1))
    id=$(basename "$s" .jsonl)
    title=$(grep -oh '"aiTitle":"[^"]*"' "$s" 2>/dev/null | tail -1 | cut -d'"' -f4)
    [ -n "$title" ] || title="(untitled)"
    size=$(du -h "$s" 2>/dev/null | cut -f1)
    msgs=$(grep -c '"type":"user"' "$s" 2>/dev/null)
    date=$(stat -c '%y' "$s" 2>/dev/null | cut -d. -f1)
    printf '  %2d) %-45.45s  %s · %s · %s msgs · %s\n' "$i" "$title" "$date" "$size" "$msgs" "${id%%-*}"
  done
  [ "$i" = 0 ] && echo "  (no sessions)"
}
```

---

## list  (default — no argument, or `list`)

Run the locator, then `list_dir "$PDIR"`. Head it with the project name (`basename "$PWD"`) and the
total size (`du -sh "$PDIR"`). Remind the user the index `<n>` is what `delete`/`rename` take.

## delete <n>

1. Resolve `<n>` to the nth file in the SAME newest-first order as `list`:
   `TARGET=$(ls -t "$PDIR"*.jsonl 2>/dev/null | sed -n "${n}p")`.
2. If empty, say "no session #n" and stop. **Never** delete the session you're currently in
   (compare its `sessionId` — skip if it matches the current one; if unsure, ask).
3. Show the target's title + date + size and **ask the user to confirm**.
4. On yes: `rm -f "$TARGET"`. Confirm how much space was freed. (Sessions aren't backed up, so this
   is purely local and permanent — the safety backup is git history of your *memory*, not transcripts.)

## clean [keep <N>]

1. `N` defaults to 5. Compute the sessions to remove = all but the N newest:
   `ls -t "$PDIR"*.jsonl 2>/dev/null | tail -n +$((N+1))`.
2. Show how many will be deleted and the total size freed, and **ask to confirm**. Exclude the current
   session from deletion.
3. On yes: `rm -f` each. Report the count and space freed.

## rename <n> <new title>

Claude Code shows a session's title from the **last** `ai-title` record in its `.jsonl`. To rename,
append a fresh one (it overrides the previous title; a resumed session may later re-title itself):

```bash
TARGET=$(ls -t "$PDIR"*.jsonl 2>/dev/null | sed -n "${n}p")
[ -n "$TARGET" ] || { echo "no session #$n"; exit 0; }
SID=$(basename "$TARGET" .jsonl)
# escape " and \ in the requested title for JSON:
T=$(printf '%s' "$new_title" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$T" "$SID" >> "$TARGET"
echo "renamed session #$n to: $new_title"
```

Tell the user the new title shows next time the session list refreshes.

## all

Iterate every project dir and print a header + `list_dir` for each:

```bash
for d in "$HOME/.claude/projects"/*/; do
  ls "$d"*.jsonl >/dev/null 2>&1 || continue
  name=$(grep -oh '"cwd":"[^"]*"' "$d"*.jsonl 2>/dev/null | head -1 | cut -d'"' -f4)
  name=$(printf '%s' "$name" | tr '\\' '/' | sed 's#.*/##'); [ -n "$name" ] || name=$(basename "$d")
  echo "── $name ($(du -sh "$d" 2>/dev/null | cut -f1)) ──"
  list_dir "$d"
done
```

For `/sessions all delete`/`clean`, apply the same delete/clean logic but make the user pick the
project + index explicitly (show the list first, then confirm each removal). Total space across all
projects: `du -sh "$HOME/.claude/projects"`.

> Sessions are transcripts only — deleting them never touches your **memory** (`memory/*.md`, which
> *is* synced) or your config. It just reclaims disk space from old conversations.
