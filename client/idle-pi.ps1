# Claude Code hook -> tells the Pi to go back to idle/bored.
# Wired to UserPromptSubmit (user has responded) and SessionEnd (user quit).
$ErrorActionPreference = 'SilentlyContinue'
$url = if ($env:CLAUDE_NOTIFY_URL) { $env:CLAUDE_NOTIFY_URL } else { 'http://claude-notify.local:8080' }
Invoke-RestMethod -Uri "$url/idle" -Method Post -TimeoutSec 2 | Out-Null
exit 0
