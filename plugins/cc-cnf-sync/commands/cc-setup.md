# /cc-setup

First-time setup — configures GitHub token and MCP automatically

## Steps to follow

### STEP 1 — Check operating system

Run:
```bash
uname -s 2>/dev/null || echo "Windows"
```

If Windows, continue. If Linux/Mac, adapt paths accordingly (use `~/.claude/` instead of `%USERPROFILE%\.claude\`).

---

### STEP 2 — Check if GitHub MCP is already working

Use the GitHub MCP to call `get_me` or any authenticated endpoint.

**If it works:** Show this message and stop:
```
✅ GitHub MCP is already configured and working.

You are ready to use:
  /cc-backup  - Upload your config to GitHub
  /cc-restore - Restore your config from GitHub
  /cc-status  - Show status and last backup date
```

**If it fails or MCP is not installed:** Continue to Step 3.

---

### STEP 3 — Run the setup script

Tell the user:
```
Running setup script...
```

Then execute:
```bash
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/setup-cc-cnf-sync.ps1"
```

Wait for the script to complete.

---

### STEP 4 — Verify the setup

After the script finishes, use the GitHub MCP to verify authentication by calling `get_me`.

**If authentication works:** Show:
```
✅ Setup complete! GitHub MCP is connected as @<username>.

Restart Claude Code and you are ready to use:
  /cc-backup  - Upload your config to GitHub
  /cc-restore - Restore your config from GitHub
  /cc-status  - Show status and last backup date
```

**If authentication still fails:** Show:
```
❌ Setup completed but GitHub authentication failed.

Please check that your token has 'repo' scope and try again:
  /cc-setup
```
