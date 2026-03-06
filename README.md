# Claude-config-sync

Claude Code plugin marketplace by Jorgeescribanogarcia.

## Install

Add this marketplace to Claude Code:

```
claude plugin marketplace add https://github.com/Jorgeescribanogarcia/Claude-config-sync
```

Then install the plugin:

```
claude plugin install claude-config-sync@jorgeescribanogarcia-marketplace
```

Restart Claude Code and run the setup:

```
/setup-config-sync
```

That's it. The setup command will ask for your GitHub token and configure everything automatically.

---

## Plugins

### claude-config-sync

Backup and restore your Claude Code configuration (settings, plugins, commands, skills, agents) to a private GitHub repository.

**Commands:**

| Command | Description |
|---|---|
| `/setup-config-sync` | First-time setup — configures GitHub token and MCP automatically |
| `/backup-config` | Upload your configuration to GitHub |
| `/restore-config` | Restore your configuration from GitHub |
| `/config-status` | Show status and last backup date |

**Requirements:**
- Claude Code v22+
- A GitHub personal access token with `repo` scope (the `/setup-config-sync` command will guide you)

---

## Uninstall

```
claude plugin uninstall claude-config-sync@jorgeescribanogarcia-marketplace
```

That's it. All commands are loaded from the plugin cache, so uninstalling the plugin removes everything cleanly. Your backups on GitHub (the `claude-code-config` repo) are not affected.
