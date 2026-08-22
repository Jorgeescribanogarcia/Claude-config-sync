# cc-cnf-sync — Roadmap / proposed changes

Ideas discussed but **not yet implemented**. Current shipped behavior is described in
[README.md](README.md); this file only tracks what's planned. (Shipped: **v4.0.x** — auth is via
the GitHub CLI, no MCP; **v4.2.0** — system-level agent skills in `~/.agents/skills` (skill.sh & co.)
sync alongside `~/.claude`; **v4.3.0** — `/sessions`, opt-in VSCode profile sync and `/config`;
**v4.4.0** — `MEMORY.md` is merged by link target, so the index stops accumulating stale
duplicates of reworded entries; see the plugin `CLAUDE.md` for architecture.)

---

## Proposed: inline conflict markers (target: a future minor)

### Context

Since **v3.0.0**, per-project memory is synced **two-way** across machines on every
`SessionStart`/`SessionEnd` (see `hooks/sync-memory.sh`). The merge is lossless: notes
present on only one machine are copied over, `MEMORY.md` is merged line by line (keyed
by link target), and when the **same note diverged** on two machines, **both versions are kept**.

### The limitation we want to fix

Today a divergence is kept as **two sibling files**:

```
project_vps_production.md            ← this machine's version (canonical)
project_vps_production.conflict.md   ← the other machine's version
```

Problem: the `.conflict.md` file is **not listed in `MEMORY.md`**, so Claude's memory
recall does not surface it. If you ask *"what's the production IP?"*, Claude answers from
the canonical file (this machine's version) and **usually won't even mention that a
conflicting version exists**. The only signal is the hook's startup message
(`"N note(s) diverged…"`), which is easy to miss. Net effect: the source of truth is
**ambiguous per machine** and the conflict can go unnoticed.

### The proposal

Stop writing a second file. Instead, embed **both versions inside the single canonical
note**, git-style:

```markdown
<<<<<<< THIS MACHINE (<hostname>)
Production IP: 187.124.1.95  (UFW closed)
=======
Production IP: 190.55.20.10  (TOTP enabled)
>>>>>>> OTHER MACHINE (<hostname>)
```

Because the conflict now lives **inside the indexed note that Claude actually reads**:

- Asking about that topic makes Claude **see the conflict block and flag it** —
  *"there are two unresolved versions: A vs B, which is correct?"* — instead of silently
  returning one machine's value.
- There is **one** file, so there's no "which file do I trust?" ambiguity.
- It's **impossible to miss**: the note stays visibly "dirty" until you resolve it by
  deleting the markers and keeping the right content.

### Comparison

| | Two files (current v3.0.0) | Inline markers (proposed) |
|---|---|---|
| Loses data? | No | No |
| Answer to "what's the IP?" | Returns local version, no warning | Flags the conflict, shows **both** |
| Can it be missed? | Yes (satellite file, not indexed) | No (inside the note Claude reads) |
| Cost | An extra file to clean up | The note reads "dirty" until resolved |

### Implementation notes

- Change `union_merge()` in `hooks/sync-memory.sh`: on a divergent note, write a single
  file containing both bodies wrapped in `<<<<<<< / ======= / >>>>>>>` markers labelled
  with each machine's hostname, instead of emitting `<name>.conflict.md`.
- Detection of an already-conflicted note (so repeated syncs don't nest markers): if the
  local file already contains a conflict marker, treat it as pending and don't re-wrap.
- Keep the startup summary message (`"N note(s) have unresolved conflicts — search for
  <<<<<<<"`).
- Update README.md's "How cross-machine memory works" merge rules accordingly.
- Bump the minor version.

### Open question

Last-write-wins was considered and rejected as a default: it silently discards the older
edit (often an equally-valid addition), and "which is newer" is unreliable across machines
(git doesn't preserve file mtimes; clocks drift). If ever wanted, it should be an opt-in
setting, never the default.

---

## Other pending items (not plugin code)

- **Run `/export` from the Windows PC** (now on the v4.x gh-based plugin) so that machine's
  projects are added to the backup. The manifest merge is additive, so exporting from any machine
  only adds/updates its own projects and never prunes the others.
- `desingsaura` legacy memory: **discarded** (an old version of AuraDesigns; not used).
