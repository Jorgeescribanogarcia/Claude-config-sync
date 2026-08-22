#!/bin/sh
# cc-cnf-sync — bidirectional per-project memory sync (SessionStart + SessionEnd).
#
# Two-way syncs this project's memory (~/.claude/projects/<slug>/memory/*.md) with
# the GitHub backup, keyed by a stable identity (normalized git remote, else folder
# name) so it follows the project across machines/OS regardless of on-disk path.
#
# Design goals, in order:
#   1. NEVER lose a note. Divergent edits keep BOTH copies; git history is the net.
#   2. Fail-open: any error exits 0 without disturbing the session.
#
# Algorithm (per project, retried on push races):
#   fetch -> reset --hard to remote truth -> file-level union merge with local
#   -> commit -> push -> copy merged result back to local.
# Union merge rules:
#   - note only on one side          -> copied to the other
#   - same note, identical           -> nothing
#   - same note, only one side edited -> that edit wins, no conflict (3-way vs the
#                                       last-synced base — editing a note is not a conflict)
#   - same note, both sides edited    -> local kept as <name>.md, remote kept as
#                                       <name>.conflict.md (on BOTH sides)
#   - MEMORY.md                      -> 3-way LINE merge keyed by each line's link target,
#                                       so rewording an entry replaces it instead of
#                                       adding a second line, and a removed entry stays
#                                       removed (a plain text union grew it forever)
#   - real-note deletions            -> NOT propagated (a note deleted on one machine
#                                       reappears from the other — safety)
#   - .conflict.md deletions         -> propagated via a <name>.conflict.md.deleted
#                                       tombstone, so resolved conflicts don't pile up

set +e

emit_context() { # $1 = message -> inject into the session as context
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$1"
}

# ── read stdin JSON ────────────────────────────────────────────────
INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || INPUT=${CC_SYNC_INPUT:-}   # background re-invocation (below) passes it via env
[ -n "$INPUT" ] || exit 0

json_str() { printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1; }
path_conv() { printf '%s' "$1" | sed 's#\\\\#\\#g; s#\\/#/#g' | tr '\\' '/'; }

# On SessionEnd the app tears the session down and cancels the still-running hook (the git
# push takes a few seconds) — that surfaces as "Hook cancelled". Detach the sync so the hook
# returns instantly: the background copy finishes the push, and SessionStart re-syncs anyway,
# so nothing is ever lost either way. SessionStart itself stays synchronous (it must emit
# context before the session uses memory).
if [ "$(json_str hook_event_name)" = "SessionEnd" ] && [ -z "$CC_SYNC_BG" ]; then
  if command -v nohup >/dev/null 2>&1; then
    CC_SYNC_BG=1 CC_SYNC_INPUT="$INPUT" nohup sh "$0" </dev/null >/dev/null 2>&1 &
  else
    CC_SYNC_BG=1 CC_SYNC_INPUT="$INPUT" sh "$0" </dev/null >/dev/null 2>&1 &
  fi
  exit 0
fi

TRANSCRIPT=$(path_conv "$(json_str transcript_path)")
CWD=$(path_conv "$(json_str cwd)")
[ -n "$TRANSCRIPT" ] || exit 0

PROJ_DIR=$(dirname "$TRANSCRIPT")
MEM_DIR="$PROJ_DIR/memory"
MARKER="$PROJ_DIR/.cc-cnf-sync-checked"

command -v git >/dev/null 2>&1 || { emit_context "cc-cnf-sync: git is not installed; memory not synced. Install git (it also provides the credential helper the sync uses)."; exit 0; }

# ── stable key (MUST match norm_key() in commands/export.md and commands/memory.md) ──
# Reads input from $nk_arg (not $1) so the three copies stay byte-identical: the two command
# copies MUST avoid $1, which Claude Code empties inside a slash command's bash at runtime.
norm_key() {
  k=$nk_arg
  case "$k" in *.git) k=${k%.git} ;; esac
  case "$k" in *@*:*) host=${k#*@}; host=${host%%:*}; path=${k#*:}; k="$host/$path" ;; esac
  k=$(printf '%s' "$k" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]*@##')
  printf '%s' "$k" | tr 'A-Z' 'a-z'
}

REMOTE=""
[ -n "$CWD" ] && REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null)
if [ -n "$REMOTE" ]; then nk_arg=$REMOTE; KEY=$(norm_key)
elif [ -n "$CWD" ]; then KEY="local/$(basename "$CWD" | tr 'A-Z' 'a-z')"
else exit 0
fi
SAFE=$(printf '%s' "$KEY" | sed 's/[^a-z0-9._-]/-/g')

# ── cache clone of the backup repo (auth via the OS git credential helper) ─
# No PAT: git authenticates through whatever credential helper the machine already
# uses for github.com — git-credential-manager on Windows, osxkeychain on macOS,
# libsecret/store/cache on Linux, or gh's helper. GIT_TERMINAL_PROMPT=0 turns a
# missing credential into a fast failure instead of hanging this (headless) hook.
CACHE="${CC_SYNC_CACHE:-$HOME/.claude/cc-cnf-sync/cache/config}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc-cnf-sync"
URL=""
resolve_repo() {
  # test seam: a plain (local, no-auth) remote for offline end-to-end testing
  if [ -n "$CC_SYNC_LOCAL_REMOTE" ]; then URL="$CC_SYNC_LOCAL_REMOTE"; return 0; fi
  # 1. explicit backup URL written by /setup (authoritative, path-independent)
  if [ -f "$CFG_DIR/repo" ]; then
    URL=$(tr -d ' \t\r\n' < "$CFG_DIR/repo" 2>/dev/null)
    [ -n "$URL" ] && return 0
  fi
  # 2. gh CLI, if installed and authenticated
  if command -v gh >/dev/null 2>&1; then
    login=$(gh api user --jq .login 2>/dev/null)
    [ -n "$login" ] && { URL="https://github.com/$login/claude-code-config.git"; return 0; }
  fi
  # 3. derive the owner from this project's origin remote — the same GitHub account
  #    that owns the project owns its claude-code-config backup.
  if [ -n "$CWD" ]; then
    r=$(git -C "$CWD" remote get-url origin 2>/dev/null)
    owner=$(printf '%s' "$r" | sed -E 's#\.git$##; s#^[a-zA-Z]+://##; s#^[^@/]*@##; s#^github\.com[:/]##; s#/.*$##')
    [ -n "$owner" ] && { URL="https://github.com/$owner/claude-code-config.git"; return 0; }
  fi
  return 1
}
# Run git non-interactively with the OS credential helper enabled (no injected header).
git_auth() { GIT_TERMINAL_PROMPT=0 git -c credential.interactive=false "$@"; }

ensure_cache() {
  [ -d "$CACHE/.git" ] && return 0            # cache present; fetch/push reuse its origin creds
  resolve_repo || return 1
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null
  git_auth clone "$URL" "$CACHE" >/dev/null 2>&1
}

if ! ensure_cache; then
  : > "$MARKER"
  if [ -z "$URL" ]; then
    emit_context "cc-cnf-sync: memory not synced — could not determine your backup repo. Run /setup, then reopen this project."
  else
    emit_context "cc-cnf-sync: could not reach your backup on GitHub. Make sure git is authenticated for github.com (its credential manager, or 'gh auth login'); memory will retry next session."
  fi
  exit 0
fi

BR=$(git -C "$CACHE" symbolic-ref --short HEAD 2>/dev/null); [ -n "$BR" ] || BR=main
MACHINE=$(hostname 2>/dev/null | sed 's/[^A-Za-z0-9._-]/-/g'); [ -n "$MACHINE" ] || MACHINE=unknown
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null); [ -n "$STAMP" ] || STAMP=0

# ── locate this project's folder in the cache, following a rename alias ─
resolve_safe() { # echoes the effective safeKey folder name to use in the cache
  s=$SAFE
  if [ ! -d "$CACHE/memory/$s" ] && [ -f "$CACHE/memory/$s.alias" ]; then
    t=$(head -n1 "$CACHE/memory/$s.alias" 2>/dev/null | tr -d ' \t\r\n')
    case "$t" in ''|*/*|.*) : ;; *) [ -d "$CACHE/memory/$t" ] && s=$t ;; esac
  fi
  printf '%s' "$s"
}

# Compare two notes ignoring line-ending (CRLF vs LF) differences, so the same note
# stored with CRLF in the backup (e.g. committed on Windows / via the web) and LF
# locally is NOT flagged as a false conflict. Returns 0 (true) only on a real diff.
notes_differ() {
  cmp -s "$1" "$2" && return 1
  [ "$(tr -d '\r' < "$1" 2>/dev/null)" = "$(tr -d '\r' < "$2" 2>/dev/null)" ] && return 1
  return 0
}

# Per-machine record of which .conflict.md files this machine has materialized. It lets
# a later plain `rm` of a resolved conflict be told apart from "this machine never had
# it", so the deletion can be propagated (via tombstones) instead of resurrecting. Kept
# in the local memory dir under a dot-name, so the *.md-only merge never syncs it.
state_has() { [ -f "$STATE" ] && grep -qxF "$1" "$STATE" 2>/dev/null; }
state_add() { state_has "$1" || printf '%s\n' "$1" >> "$STATE" 2>/dev/null; }
state_del() { [ -f "$STATE" ] || return 0; grep -vxF "$1" "$STATE" 2>/dev/null > "$STATE.tmp"; mv "$STATE.tmp" "$STATE" 2>/dev/null; }

# 3-way merge support. hash_note() is the CRLF-normalized content hash (via git, always
# present). base_get() returns the hash of a note as this machine last SYNCED it — the
# common ancestor — so union_merge can tell "only I edited this note" (take the edit, no
# conflict) from "both sides changed since we last agreed" (a real conflict). The base is
# per-machine (never synced) and refreshed only after a successful sync (record_bases).
hash_note() { tr -d '\r' < "$1" 2>/dev/null | git hash-object --stdin 2>/dev/null; }
base_get()  { [ -f "$BASEFILE" ] && awk -v n="$1" '$2==n{print $1; exit}' "$BASEFILE" 2>/dev/null; }
record_bases() { # $1 = local memory dir — snapshot every note's hash as the new base
  bf="$1/.cc-cnf-sync-base"
  { for f in "$1"/*.md; do [ -e "$f" ] || continue
      b=$(basename "$f"); case "$b" in *.conflict.md) continue ;; esac
      printf '%s %s\n' "$(hash_note "$f")" "$b"
    done; } > "$bf.tmp" 2>/dev/null
  mv "$bf.tmp" "$bf" 2>/dev/null
  # …and a full COPY of the index, because MEMORY.md is merged line by line: a
  # content hash only answers "did it change", and the line merge needs to know
  # WHICH entries existed at the last sync to tell a deletion from a new arrival.
  cp "$1/MEMORY.md" "$1/.cc-cnf-sync-memory-base" 2>/dev/null
}

# ── file-level union merge of $1 (remote/cache dir) and $2 (local dir) ─
# Ends with BOTH dirs holding the union; conflicts keep both copies.
union_merge() {
  cdir=$1; ldir=$2
  mkdir -p "$cdir" "$ldir" 2>/dev/null
  STATE="$ldir/.cc-cnf-sync-conflicts"
  BASEFILE="$ldir/.cc-cnf-sync-base"
  # Deliberate real-note deletions (from the /memory command) propagate via a
  # <note>.md.deleted tombstone. Apply them FIRST so the loops below can't resurrect the
  # note. Accidental `rm` of a real note does NOT create a tombstone (only /memory does),
  # so it still safely reappears — this branch only fires on an intentional deletion.
  for tomb in "$cdir"/*.md.deleted; do
    [ -e "$tomb" ] || continue
    case "$tomb" in *.conflict.md.deleted) continue ;; esac   # conflict tombstones handled in the lifecycle below
    t=$(basename "${tomb%.deleted}")                          # <note>.md
    rm -f "$cdir/$t" "$ldir/$t" 2>/dev/null
  done
  # remote -> local
  for rf in "$cdir"/*.md; do
    [ -e "$rf" ] || continue
    base=$(basename "$rf")
    case "$base" in *.conflict.md) continue ;; esac
    lf="$ldir/$base"
    if [ "$base" = "MEMORY.md" ]; then continue; fi   # handled separately below
    if [ ! -e "$lf" ]; then
      cp "$rf" "$lf" 2>/dev/null
    elif notes_differ "$rf" "$lf"; then
      # 3-way merge against the last-synced base, so editing a note doesn't self-conflict.
      bh=$(base_get "$base"); lh=$(hash_note "$lf"); rh=$(hash_note "$rf")
      if [ -n "$bh" ] && [ "$rh" = "$bh" ] && [ "$lh" != "$bh" ]; then
        cp "$lf" "$cdir/$base" 2>/dev/null                   # only THIS machine edited → local wins, no conflict
      elif [ -n "$bh" ] && [ "$lh" = "$bh" ] && [ "$rh" != "$bh" ]; then
        cp "$rf" "$lf" 2>/dev/null                           # only the backup changed → pull it, no conflict
      else
        cf="${base%.md}.conflict.md"                         # both sides changed since the base (or no base) → real conflict
        rm -f "$cdir/$cf.deleted" 2>/dev/null                # a fresh divergence overrides a stale tombstone
        cp "$rf" "$ldir/$cf" 2>/dev/null                     # keep remote copy locally
        cp "$rf" "$cdir/$cf" 2>/dev/null                     # and propagate the marker
        cp "$lf" "$cdir/$base" 2>/dev/null                   # local wins as canonical
        state_add "$cf"
      fi
    fi
  done
  # local -> remote (files the cache does not have yet)
  for lf in "$ldir"/*.md; do
    [ -e "$lf" ] || continue
    base=$(basename "$lf")
    case "$base" in *.conflict.md) continue ;; esac
    [ "$base" = "MEMORY.md" ] && continue
    [ -e "$cdir/$base.deleted" ] && { rm -f "$lf" 2>/dev/null; continue; }   # tombstoned real note → don't resurrect
    [ -e "$cdir/$base" ] || cp "$lf" "$cdir/$base" 2>/dev/null
  done
  # MEMORY.md: 3-way LINE merge keyed by the note each line links to.
  # Every index line is `- [Title](<note>.md) — hook`, so the LINK TARGET is the entry's
  # identity; the surrounding text is just its current wording. Deduping by exact text
  # (what this did before) treated a reworded line as a NEW entry, so both survived and
  # the stale one kept coming back from the backup — the index grew without bound until
  # it was loaded truncated. Keying on the target collapses every wording of an entry to
  # one line, and the base (the index as this machine last synced it) lets a deletion or
  # a rewording propagate instead of resurrecting. Lines with no link (headings, blanks)
  # fall back to their literal text.
  if [ -e "$cdir/MEMORY.md" ] || [ -e "$ldir/MEMORY.md" ]; then
    IBASE="$ldir/.cc-cnf-sync-memory-base"
    hb=0; [ -s "$IBASE" ] && hb=1          # no base yet (first sync / older install) → plain union, never delete
    { [ -s "$IBASE" ] && sed 's/^/B/' "$IBASE"
      [ -e "$cdir/MEMORY.md" ] && sed 's/^/R/' "$cdir/MEMORY.md"
      [ -e "$ldir/MEMORY.md" ] && sed 's/^/L/' "$ldir/MEMORY.md"
    } 2>/dev/null | awk -v HB="$hb" '
      function key(l,   p,s,q) {
        p = index(l, "](")
        if (p > 0) { s = substr(l, p+2); q = index(s, ")"); if (q > 0) return "T:" substr(s, 1, q-1) }
        return "L:" l
      }
      { t = substr($0,1,1); l = substr($0,2); sub(/\r$/, "", l); k = key(l) }
      t == "B" { if (!(k in bs)) { bs[k]=1; bt[k]=l } ; next }
      t == "R" { if (!(k in rs)) { rs[k]=1; rt[k]=l; ro[++rn]=k } ; next }
               { if (!(k in ls)) { ls[k]=1; lt[k]=l; lo[++ln]=k } }
      END {
        for (i = 1; i <= ln; i++) { k = lo[i]
          if (k in rs) {                                  # on both sides: local wording is canonical,
            if (HB && (k in bs) && lt[k] == bt[k] && rt[k] != bt[k]) print rt[k]
            else print lt[k]                              # …unless only the backup reworded it
            out[k] = 1; continue
          }
          if (HB && (k in bs)) continue                   # was in the base, gone from the backup → deleted elsewhere
          print lt[k]; out[k] = 1                         # new here → push it up
        }
        for (i = 1; i <= rn; i++) { k = ro[i]
          if (k in out) continue
          if (HB && (k in bs)) continue                   # was in the base, gone locally → deleted here
          print rt[k]                                     # new in the backup → pull it down
        }
      }' > "$cdir/MEMORY.md.tmp" 2>/dev/null
    # An empty result is never written: it would mean "drop the whole index", which no
    # legitimate merge produces (a real emptying is a deletion of every note, and those
    # go through the tombstone path).
    if [ -s "$cdir/MEMORY.md.tmp" ]; then
      cp "$cdir/MEMORY.md.tmp" "$cdir/MEMORY.md" 2>/dev/null
      cp "$cdir/MEMORY.md.tmp" "$ldir/MEMORY.md" 2>/dev/null
    elif [ -e "$cdir/MEMORY.md" ]; then
      cp "$cdir/MEMORY.md" "$ldir/MEMORY.md" 2>/dev/null   # …and the local side is restored from it
    fi
    rm -f "$cdir/MEMORY.md.tmp" 2>/dev/null
  fi
  # ── conflict-file lifecycle (tombstones propagate a resolved-and-deleted conflict) ──
  # Real notes never propagate deletions (safety); .conflict.md files are ephemeral
  # markers, so a deleted one SHOULD disappear everywhere. A `<name>.conflict.md.deleted`
  # tombstone (empty, kept in the backup) carries that removal to every machine.
  # a) apply incoming tombstones: a conflict resolved on another machine is removed here too
  for tomb in "$cdir"/*.conflict.md.deleted; do
    [ -e "$tomb" ] || continue
    cf=$(basename "${tomb%.deleted}")
    rm -f "$cdir/$cf" "$ldir/$cf" 2>/dev/null
    state_del "$cf"
  done
  # b) reconcile the conflict files the backup still holds
  for cfp in "$cdir"/*.conflict.md; do
    [ -e "$cfp" ] || continue
    b=$(basename "$cfp")
    if [ -e "$cdir/$b.deleted" ]; then rm -f "$cdir/$b" 2>/dev/null; continue; fi
    if [ -e "$ldir/$b" ]; then
      state_add "$b"                              # still present locally
    elif state_has "$b"; then
      : > "$cdir/$b.deleted"                      # this machine had it and you deleted it → tombstone
      rm -f "$cdir/$b" 2>/dev/null                # …and drop it from the backup
      state_del "$b"
    else
      cp "$cfp" "$ldir/$b" 2>/dev/null            # new to this machine → materialize it
      state_add "$b"
    fi
  done
  # c) conflicts freshly created on THIS machine that the backup lacks → push them up
  for lfp in "$ldir"/*.conflict.md; do
    [ -e "$lfp" ] || continue
    b=$(basename "$lfp")
    if [ -e "$cdir/$b.deleted" ]; then rm -f "$ldir/$b" 2>/dev/null; state_del "$b"; continue; fi
    [ -e "$cdir/$b" ] || cp "$lfp" "$cdir/$b" 2>/dev/null
    state_add "$b"
  done
}

# ── global user config sync (in addition to per-project memory) ────────
# Continuously syncs the user-level config the same conflict-safe, 3-way way as memory,
# so editing your global CLAUDE.md / commands / skills / agents on one machine reaches the
# others automatically. STRICT ALLOWLIST — nothing else is ever touched. Anything
# machine-specific belongs in settings.local.json, which is intentionally NOT in the list.
CFGHOME="${CC_SYNC_CONFIG_HOME:-$HOME/.claude}"     # test seam for offline end-to-end tests
AGENTS_HOME="${CC_SYNC_AGENTS_HOME:-$HOME/.agents}" # system-level agent skills (skill.sh & co.), test seam
CFG_BASE="$CFG_DIR/config-base"                     # machine-level 3-way base (relpath -> hash)
CONFIG_FILES="CLAUDE.md settings.json keybindings.json plugins.json"
CONFIG_TREES="commands skills agents"

# VSCode profile sync is OPT-IN — default OFF, toggled by /config (stored in $CFG_DIR/config as
# `vscode_sync=on`). When on, we mirror the VSCode *User* profile (allowlist below) under `vscode/`
# in the backup; the machine-specific globalStorage/workspaceStorage/History/sync dirs are NEVER touched.
cfg_flag() { [ -f "$CFG_DIR/config" ] && awk -F= -v k="$1" '$1==k{print $2; exit}' "$CFG_DIR/config" 2>/dev/null; }
vscode_enabled() { [ "$(cfg_flag vscode_sync)" = "on" ]; }
VSCODE_USER="${CC_SYNC_VSCODE_HOME:-}"              # VSCode "User" config dir; test seam
if [ -z "$VSCODE_USER" ]; then
  for p in "${APPDATA:-}/Code/User" "$HOME/.config/Code/User" "$HOME/Library/Application Support/Code/User"; do
    [ -d "$p" ] && { VSCODE_USER="$p"; break; }
  done
fi
VSCODE_FILES="settings.json keybindings.json tasks.json locale.json argv.json"

cfgbase_get() { [ -f "$CFG_BASE" ] || return; awk -v n="$1" '{p=$0;sub(/^[^ ]* /,"",p); if(p==n){print $1;exit}}' "$CFG_BASE" 2>/dev/null; }

# 3-way merge one config file: rel=identity (for the base), lf=local path, cf=cache path.
# Deletions are NOT propagated (a file only on one side is copied to the other — safety).
# A true two-sided change keeps local canonical and saves the remote as a .cc-conflict sidecar.
merge_one() {
  rel=$1; lf=$2; cf=$3
  if [ ! -e "$lf" ] && [ ! -e "$cf" ]; then return; fi
  if [ ! -e "$lf" ]; then mkdir -p "$(dirname "$lf")" 2>/dev/null; cp "$cf" "$lf" 2>/dev/null; return; fi
  if [ ! -e "$cf" ]; then mkdir -p "$(dirname "$cf")" 2>/dev/null; cp "$lf" "$cf" 2>/dev/null; return; fi
  notes_differ "$cf" "$lf" || return
  bh=$(cfgbase_get "$rel"); lh=$(hash_note "$lf"); rh=$(hash_note "$cf")
  if [ -n "$bh" ] && [ "$rh" = "$bh" ] && [ "$lh" != "$bh" ]; then cp "$lf" "$cf" 2>/dev/null            # only local edited
  elif [ -n "$bh" ] && [ "$lh" = "$bh" ] && [ "$rh" != "$bh" ]; then cp "$cf" "$lf" 2>/dev/null          # only backup edited
  else cp "$cf" "$lf.cc-conflict" 2>/dev/null; cp "$cf" "$cf.cc-conflict" 2>/dev/null; cp "$lf" "$cf" 2>/dev/null; fi
}

sync_tree() { # $1=local root  $2=cache root  $3=rel prefix — per-file 3-way over a directory
  lr=$1; cr=$2; pfx=$3
  { [ -d "$lr" ] && ( cd "$lr" && find . -type f ! -name '*.cc-conflict' 2>/dev/null | sed 's#^\./##' )
    [ -d "$cr" ] && ( cd "$cr" && find . -type f ! -name '*.cc-conflict' 2>/dev/null | sed 's#^\./##' ); } \
  | sort -u | while IFS= read -r rp; do
      [ -n "$rp" ] || continue
      merge_one "$pfx/$rp" "$lr/$rp" "$cr/$rp"
    done
}

sync_config() {
  for f in $CONFIG_FILES; do merge_one "$f" "$CFGHOME/$f" "$CACHE/$f"; done
  for d in $CONFIG_TREES; do sync_tree "$CFGHOME/$d" "$CACHE/$d" "$d"; done
  # System-level agent skills (skill.sh & co.) live OUTSIDE ~/.claude, at ~/.agents/skills. Mirror
  # them under the cache namespace `agents-skills/` (+ the portable install lock). Naturally a no-op
  # when ~/.agents is absent (sync_tree guards on the local dir; merge_one returns if neither side exists).
  sync_tree "$AGENTS_HOME/skills" "$CACHE/agents-skills" "agents-skills"
  merge_one "agents-skill-lock.json" "$AGENTS_HOME/.skill-lock.json" "$CACHE/agents-skill-lock.json"
  # VSCode profile — OPT-IN (see /config). Allowlist of user config files + snippets/ + a portable
  # extensions manifest (reinstalled by /import). Never touches globalStorage/workspaceStorage/etc.
  if vscode_enabled && [ -n "$VSCODE_USER" ]; then
    for f in $VSCODE_FILES; do merge_one "vscode/$f" "$VSCODE_USER/$f" "$CACHE/vscode/$f"; done
    sync_tree "$VSCODE_USER/snippets" "$CACHE/vscode/snippets" "vscode/snippets"
    if command -v code >/dev/null 2>&1; then
      mkdir -p "$CFG_DIR" 2>/dev/null
      code --list-extensions 2>/dev/null | sort > "$CFG_DIR/vscode-extensions.txt"
      merge_one "vscode/extensions.txt" "$CFG_DIR/vscode-extensions.txt" "$CACHE/vscode/extensions.txt"
    fi
  fi
}

record_config_bases() {  # snapshot the just-synced config hashes as the new 3-way base
  mkdir -p "$CFG_DIR" 2>/dev/null
  { for f in $CONFIG_FILES; do [ -f "$CFGHOME/$f" ] && printf '%s %s\n' "$(hash_note "$CFGHOME/$f")" "$f"; done
    for d in $CONFIG_TREES; do [ -d "$CFGHOME/$d" ] && ( cd "$CFGHOME" && find "$d" -type f ! -name '*.cc-conflict' 2>/dev/null ) | while IFS= read -r rp; do
        printf '%s %s\n' "$(hash_note "$CFGHOME/$rp")" "$rp"; done; done
    # system-level agent skills (mirrored under `agents-skills/`) + the portable install lock —
    # same relpath identities merge_one/sync_config use, so the 3-way base lines up.
    [ -f "$AGENTS_HOME/.skill-lock.json" ] && printf '%s %s\n' "$(hash_note "$AGENTS_HOME/.skill-lock.json")" "agents-skill-lock.json"
    [ -d "$AGENTS_HOME/skills" ] && ( cd "$AGENTS_HOME/skills" && find . -type f ! -name '*.cc-conflict' 2>/dev/null | sed 's#^\./##' ) | while IFS= read -r rp; do
        printf '%s %s\n' "$(hash_note "$AGENTS_HOME/skills/$rp")" "agents-skills/$rp"; done
    # VSCode profile (only when opted in) — same relpaths sync_config uses.
    if vscode_enabled && [ -n "$VSCODE_USER" ]; then
      for f in $VSCODE_FILES; do [ -f "$VSCODE_USER/$f" ] && printf '%s %s\n' "$(hash_note "$VSCODE_USER/$f")" "vscode/$f"; done
      [ -d "$VSCODE_USER/snippets" ] && ( cd "$VSCODE_USER/snippets" && find . -type f ! -name '*.cc-conflict' 2>/dev/null | sed 's#^\./##' ) | while IFS= read -r rp; do
          printf '%s %s\n' "$(hash_note "$VSCODE_USER/snippets/$rp")" "vscode/snippets/$rp"; done
      [ -f "$CFG_DIR/vscode-extensions.txt" ] && printf '%s %s\n' "$(hash_note "$CFG_DIR/vscode-extensions.txt")" "vscode/extensions.txt"
    fi
  } > "$CFG_BASE.tmp" 2>/dev/null
  mv "$CFG_BASE.tmp" "$CFG_BASE" 2>/dev/null
}

# ── sync loop (retry on push race) ─────────────────────────────────
had_local=0
find "$MEM_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q . && had_local=1
synced=0
i=1
while [ "$i" -le 3 ]; do
  git_auth -C "$CACHE" fetch --quiet origin "$BR" >/dev/null 2>&1
  git -C "$CACHE" reset --hard "origin/$BR" >/dev/null 2>&1 || git -C "$CACHE" reset --hard >/dev/null 2>&1
  EFF=$(resolve_safe)
  CDIR="$CACHE/memory/$EFF"

  union_merge "$CDIR" "$MEM_DIR"
  sync_config                             # global user config (CLAUDE.md, commands/skills/agents, …)

  git -C "$CACHE" add -A >/dev/null 2>&1   # stage this project's memory AND any global config changes
  if git -C "$CACHE" diff --cached --quiet 2>/dev/null; then
    synced=1; break                       # nothing to push; local already updated from remote
  fi
  git -C "$CACHE" -c user.name="cc-cnf-sync" -c user.email="cc-cnf-sync@$MACHINE" \
      commit -q -m "cc-cnf-sync: $EFF memory + user config from $MACHINE @ $STAMP" >/dev/null 2>&1
  if git_auth -C "$CACHE" push --quiet origin "$BR" >/dev/null 2>&1; then
    synced=1; break
  fi
  i=$((i+1))                              # push rejected → loop: refetch, remerge, retry
done

: > "$MARKER"

if [ "$synced" = 1 ]; then
  record_bases "$MEM_DIR"                 # snapshot the just-synced content as the 3-way base
  record_config_bases                     # …and the global-config base
  N=$(find "$MEM_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  C=$(find "$MEM_DIR" -maxdepth 1 -type f -name '*.conflict.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$had_local" = 0 ] && [ "$N" -gt 0 ]; then
    msg="cc-cnf-sync: synced ${N} memory note(s) for this project from your backup (key: ${KEY})."
  else
    msg="cc-cnf-sync: memory synced with your backup (${N} note(s), key: ${KEY})."
  fi
  [ "$C" -gt 0 ] && msg="${msg} ${C} note(s) diverged across machines and were kept as .conflict.md for you to reconcile."
  emit_context "$msg"
else
  emit_context "cc-cnf-sync: memory sync could not complete this session (push contention or network); your local notes are untouched and it will retry next session."
fi
exit 0
