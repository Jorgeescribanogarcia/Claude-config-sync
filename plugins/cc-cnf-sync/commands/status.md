# /status

Show current Claude Code configuration status and last backup information.

## Steps to follow

### STEP 1 — Gather local information

Run the following commands:

```bash
# Claude Code version
claude --version

# Installed plugins
claude plugin list

# MCP servers
claude mcp list
```

---

### STEP 2 — Check last backup on GitHub

If the GitHub MCP is available and the session is active:
- Use the GitHub MCP to read `backup-meta.json` from the `claude-code-config` repository
- Extract: `backup_date`, `hostname`, `claude_version`

If the GitHub MCP is not available or not authenticated:
- Show: `Could not connect to GitHub — run /setup first`

---

### STEP 3 — Display status

```
📊 Configuration Status — Claude Code

🖥️  Local version: <claude --version>
📁 Config path: %USERPROFILE%\.claude\

INSTALLED PLUGINS:
  <list from claude plugin list>

MCP SERVERS:
  <list from claude mcp list>

LAST GITHUB BACKUP:
  📅 Date: <backup_date or "Never">
  🖥️  Machine: <hostname or "—">
  🔖 Version: <claude_version or "—">
  🔗 Repo: https://github.com/<username>/claude-code-config

DAYS SINCE LAST BACKUP: <days or "N/A">
```

If more than 7 days have passed since the last backup, show:
```
⚠️  It has been more than 7 days since your last backup.
    Run /backup to update it.
```
