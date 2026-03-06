# /backup-config

Backup all Claude Code configuration files to a private GitHub repository.

## Steps to follow

### STEP 1 — Pre-flight checks

Run this command to check if the GitHub MCP is installed:

```bash
claude mcp list
```

Look for any entry containing "github" in the output.

**If GitHub MCP is NOT found**, stop and show:
```
❌ GitHub MCP not found.

Install it by running:
  claude mcp add github npx @modelcontextprotocol/server-github

Then restart Claude Code and run /backup-config again.
```

**If GitHub MCP IS found**, continue to Step 2.

---

### STEP 2 — Verify GitHub session

Use the GitHub MCP to verify the authenticated user (e.g., call `get_me` or equivalent).

**If unauthenticated or the call fails**, stop and show:
```
❌ No active GitHub session.

Make sure the GITHUB_PERSONAL_ACCESS_TOKEN environment variable is set
with a valid token that has 'repo' scope.
```

**If authenticated**, save the username and continue.

---

### STEP 3 — Check or create backup repository

Use the GitHub MCP to check if a repository called `claude-code-config` exists for the authenticated user.

- If it does **NOT exist**: create it as a **private** repository with description:
  `Automated backup and restore of Claude Code configuration files (settings, plugins, commands, skills, agents) synced to a private GitHub repository.`
- If it **exists**: continue.

Show:
```
✅ GitHub MCP detected
✅ Active session as @<username>
✅ Repository: github.com/<username>/claude-code-config
```

---

### STEP 4 — Collect configuration files

Run the following PowerShell to collect all config files into a temp directory:

```powershell
$TEMP_DIR = "$env:TEMP\claude-config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

$SOURCE = "$env:USERPROFILE\.claude"
$FILES_TO_BACKUP = @(
  "settings.json",
  "CLAUDE.md",
  "keybindings.json",
  "plugins\installed_plugins.json",
  "plugins\known_marketplaces.json"
)

foreach ($file in $FILES_TO_BACKUP) {
  $src = Join-Path $SOURCE $file
  $dst = Join-Path $TEMP_DIR $file
  if (Test-Path $src) {
    $dstDir = Split-Path $dst -Parent
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    Copy-Item $src $dst -Force
  }
}

foreach ($dir in @("commands", "skills", "agents")) {
  $srcDir = Join-Path $SOURCE $dir
  if (Test-Path $srcDir) {
    Copy-Item $srcDir (Join-Path $TEMP_DIR $dir) -Recurse -Force
  }
}

Write-Output $TEMP_DIR
```

**IMPORTANT — Never include these files:**
- `.credentials.json`
- `settings.local.json`
- `history.jsonl`
- `~/.claude.json`
- Any file containing "token", "secret", or "key" in its name

---

### STEP 5 — Add metadata file

Create a file called `backup-meta.json` in the temp directory:

```json
{
  "backup_date": "<ISO timestamp>",
  "claude_version": "<output of: claude --version>",
  "os": "Windows",
  "hostname": "<output of: hostname>"
}
```

---

### STEP 6 — Upload files to GitHub

Use the GitHub MCP to upload each collected file to the `claude-code-config` repository, preserving the directory structure.

Use this commit message:
```
backup: <date> - Claude Code config sync
```

Show progress as each file is uploaded.

---

### STEP 7 — Final summary

```
✅ Backup completed

📦 Files uploaded: <count>
🔗 Repository: https://github.com/<username>/claude-code-config
📅 Date: <timestamp>

Included:
  ✓ settings.json
  ✓ CLAUDE.md
  ✓ plugins/installed_plugins.json
  ✓ commands/ (<n> files)
  ✓ skills/ (<n> files)
  ✓ agents/ (<n> files)

Excluded for security:
  ⊘ .credentials.json
  ⊘ settings.local.json
  ⊘ history.jsonl
```
