# /restore-config

Restore Claude Code configuration from the GitHub backup repository.

## Steps to follow

### STEP 1 — Pre-flight checks

Run:
```bash
claude mcp list
```

**If GitHub MCP is NOT found**, stop and show:
```
❌ GitHub MCP not found.

Install it by running:
  claude mcp add github npx @modelcontextprotocol/server-github

Then restart Claude Code and run /restore-config again.
```

**If found**, continue.

---

### STEP 2 — Verify GitHub session

Use the GitHub MCP to verify authentication.

**If not authenticated**, stop and show:
```
❌ No active GitHub session.

Make sure the GITHUB_PERSONAL_ACCESS_TOKEN environment variable is set
with a valid token that has 'repo' scope.
```

**If authenticated**, save the username and continue.

---

### STEP 3 — Check backup repository exists

Use the GitHub MCP to check if `claude-code-config` exists for the authenticated user.

**If NOT found**, stop and show:
```
❌ Backup repository not found.

You haven't created a backup yet. Run /backup-config first.
```

**If found**, continue.

---

### STEP 4 — Show backup info and ask for confirmation

Use the GitHub MCP to read `backup-meta.json` from the repo and show:

```
📦 Backup found

  📅 Backup date: <backup_date>
  🖥️  Machine: <hostname>
  🔖 Claude Code version: <claude_version>
  🔗 Repository: https://github.com/<username>/claude-code-config

⚠️  This will overwrite your current configuration at:
    %USERPROFILE%\.claude\

Continue with restore? (reply: yes / no)
```

Wait for user confirmation. If the user replies anything other than affirmative, stop.

---

### STEP 5 — Create a local safety backup

Before overwriting anything, back up the current config:

```powershell
$SAFETY_BACKUP = "$env:USERPROFILE\.claude-before-restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item "$env:USERPROFILE\.claude" $SAFETY_BACKUP -Recurse -Force
Write-Output "Safety backup created at: $SAFETY_BACKUP"
```

Show:
```
🛡️  Safety backup created at:
    %USERPROFILE%\.claude-before-restore-<timestamp>
    (in case you need to roll back)
```

---

### STEP 6 — Download and restore files

Use the GitHub MCP to list all files in the `claude-code-config` repository.

For each file (excluding `backup-meta.json`):
1. Download the file content using the GitHub MCP
2. Determine the correct local path under `%USERPROFILE%\.claude\`
3. Create any necessary subdirectories
4. Write the file to the correct location

Mapping:
- `settings.json` → `%USERPROFILE%\.claude\settings.json`
- `CLAUDE.md` → `%USERPROFILE%\.claude\CLAUDE.md`
- `keybindings.json` → `%USERPROFILE%\.claude\keybindings.json`
- `plugins/installed_plugins.json` → `%USERPROFILE%\.claude\plugins\installed_plugins.json`
- `plugins/known_marketplaces.json` → `%USERPROFILE%\.claude\plugins\known_marketplaces.json`
- `commands/*` → `%USERPROFILE%\.claude\commands\`
- `skills/**` → `%USERPROFILE%\.claude\skills\`
- `agents/**` → `%USERPROFILE%\.claude\agents\`

Show progress as each file is restored.

---

### STEP 7 — Final summary

```
✅ Restore completed

📁 Files restored: <count>
📅 Backup applied: <backup_date>

⚠️  Restart Claude Code to apply all changes.

🛡️  If something looks wrong, your previous config is at:
    %USERPROFILE%\.claude-before-restore-<timestamp>
```
