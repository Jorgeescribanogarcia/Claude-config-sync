# setup-cc-cnf-sync.ps1
# Full setup: cleans previous install + installs GitHub MCP + configures token
# This script is called automatically by /setup

param(
    [string]$Token = ""
)

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  cc-cnf-sync - Setup" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# ── STEP 1: Clean previous GitHub MCP ────────────────────
Write-Host "STEP 1/2 - Cleaning previous GitHub MCP..." -ForegroundColor Yellow

$MCP_LIST = claude mcp list 2>&1
if ($MCP_LIST -match "github") {
    claude mcp remove github --scope user 2>&1 | Out-Null
    Write-Host "  Removed previous GitHub MCP." -ForegroundColor DarkGray
} else {
    Write-Host "  No previous GitHub MCP found." -ForegroundColor DarkGray
}
Write-Host ""

# ── STEP 2: GitHub token ──────────────────────────────────
Write-Host "STEP 2/2 - GitHub token setup..." -ForegroundColor Yellow
Write-Host ""

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "  You need a GitHub Personal Access Token with 'repo' scope." -ForegroundColor White
    Write-Host "  Create one at: https://github.com/settings/tokens" -ForegroundColor Cyan
    Write-Host ""
    $Token = Read-Host "  Paste your GitHub token"
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "  ERROR: No token provided. Setup cancelled." -ForegroundColor Red
    exit 1
}

# Install GitHub MCP
claude mcp add github npx @modelcontextprotocol/server-github --env "GITHUB_PERSONAL_ACCESS_TOKEN=$Token" --scope user
if ($LASTEXITCODE -eq 0) {
    Write-Host "  GitHub MCP installed successfully." -ForegroundColor Green
} else {
    Write-Host "  ERROR: Could not install GitHub MCP." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restart Claude Code and you are ready to use:" -ForegroundColor White
Write-Host "  /backup  - Upload your config to GitHub" -ForegroundColor Cyan
Write-Host "  /restore - Restore your config from GitHub" -ForegroundColor Cyan
Write-Host "  /status  - Show status and last backup date" -ForegroundColor Cyan
Write-Host ""
