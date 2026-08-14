# /config

Show or change **cc-cnf-sync** options. Options are stored per-machine in a tiny key=value file at
`~/.config/cc-cnf-sync/config` (nothing secret; it is not synced). Today the main option is the
**opt-in VSCode profile sync**, off by default.

The text after `/config` (`$ARGUMENTS`) selects the action:

- `/config`                    → show the current configuration
- `/config vscode on`          → enable syncing your VSCode profile (settings, keybindings, snippets, tasks, extensions)
- `/config vscode off`         → disable it

Works on **Linux, macOS and Windows** (Git Bash).

---

## Helpers (used by every action)

```bash
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc-cnf-sync"
CFG="$CFG_DIR/config"
get_flag() { [ -f "$CFG" ] && awk -F= -v k="$1" '$1==k{print $2; exit}' "$CFG"; }
set_flag() {  # $1=key $2=value  (upsert one line)
  mkdir -p "$CFG_DIR"
  { [ -f "$CFG" ] && grep -v "^$1=" "$CFG"; printf '%s=%s\n' "$1" "$2"; } > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
}
```

## show  (default — no argument)

Print the current options and where they live. Example:

```bash
echo "cc-cnf-sync — configuración ($CFG)"
echo "  vscode_sync = $(get_flag vscode_sync 2>/dev/null || echo off)   (sync del perfil de VSCode)"
```

Explain that **VSCode sync is off by default**, that turning it on mirrors the VSCode *User* profile
(`settings.json`, `keybindings.json`, `tasks.json`, `snippets/`, and the extensions list) to the
backup with the same conflict-safe 3-way merge as everything else, and that the machine-specific
`globalStorage/`, `workspaceStorage/`, `History/` and `sync/` folders are never touched.

## vscode on | off

1. Read the requested value from `$ARGUMENTS` (`on` or `off`). Anything else → show usage and stop.
2. `set_flag vscode_sync on` (or `off`).
3. On **on**: check `command -v code` and the VSCode User dir (`$APPDATA/Code/User` on Windows,
   `~/.config/Code/User` on Linux, `~/Library/Application Support/Code/User` on macOS).
   - If neither is found, warn that VSCode doesn't seem installed here, so nothing will sync **on this
     machine** until it is (the flag is still saved; it's a no-op meanwhile).
   - Otherwise confirm it's enabled and that the VSCode profile will start syncing on the **next
     session** (SessionStart/SessionEnd) — no restart needed. Extensions are captured as a portable
     list and reinstalled by `/import` on other machines.
4. On **off**: confirm it's disabled. Already-uploaded `vscode/` files stay in the backup (deletions
   aren't auto-propagated); they simply stop updating.

> Turning the flag on/off is per-machine and instant. The actual VSCode sync runs inside the normal
> memory-sync hook, so there's nothing else to start or stop.
