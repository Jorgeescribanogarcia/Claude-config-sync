# cc-cnf-sync

Backup and restore your Claude Code configuration (settings, plugins, commands, skills, agents) to a private GitHub repository.

## Commands

| Command | Description |
|---|---|
| `/setup` | First-time setup — configures GitHub token and MCP automatically |
| `/backup` | Upload your configuration to GitHub |
| `/restore` | Restore your configuration from GitHub |
| `/status` | Show status and last backup date |

## Requirements

- Claude Code v22+
- A GitHub personal access token with `repo` scope (the `/setup` command will guide you)

## Quick start

```
claude plugin install cc-cnf-sync@jeg
```

Restart Claude Code, then run:

```
/setup
```

## Uninstall

```
claude plugin uninstall cc-cnf-sync@jeg
```

Your backups on GitHub (the `claude-code-config` repo) are not affected.
