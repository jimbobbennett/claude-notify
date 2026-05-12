# Claude Notify installer — native Windows / PowerShell.
#
# Copies hook-pi.ps1 into %USERPROFILE%\.claude\hooks\ and merges the
# seven hook entries (Notification, Stop, UserPromptSubmit, SessionEnd,
# SessionStart, PreToolUse, PostToolUse) into settings.json. Safe to
# re-run; also scrubs entries from older installs that pointed at
# notify-pi.ps1 / idle-pi.ps1.
[CmdletBinding()]
param(
  [string]$Url,
  [string]$Settings = (Join-Path $env:USERPROFILE '.claude\settings.json')
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hooksDir  = Join-Path $claudeDir 'hooks'

# 1. Copy hook script.
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
Copy-Item -Force (Join-Path $scriptDir 'hook-pi.ps1') $hooksDir
Write-Host "Installed hook-pi.ps1 to $hooksDir"

foreach ($old in @('notify-pi.ps1','idle-pi.ps1')) {
  $oldPath = Join-Path $hooksDir $old
  if (Test-Path $oldPath) {
    Remove-Item -Force $oldPath
    Write-Host "Removed obsolete $oldPath"
  }
}

# 2. Persist CLAUDE_NOTIFY_URL if requested.
if ($Url) {
  [Environment]::SetEnvironmentVariable('CLAUDE_NOTIFY_URL', $Url, 'User')
  Write-Host "Set CLAUDE_NOTIFY_URL=$Url for the current user (open a new shell to pick it up)"
}

# 3. Merge hook entries into settings.json.
$hookBase = '& "$env:USERPROFILE\.claude\hooks\hook-pi.ps1"'

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Settings) | Out-Null
if (-not (Test-Path $Settings)) {
  '{}' | Set-Content -Path $Settings -Encoding UTF8
}

try {
  $json = Get-Content -Raw $Settings | ConvertFrom-Json
} catch {
  Write-Error "ERROR: $Settings is not valid JSON. Fix it before re-running."
  exit 1
}
if ($null -eq $json) { $json = [PSCustomObject]@{} }

$backup = "$Settings.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
Copy-Item -Force $Settings $backup

if (-not $json.PSObject.Properties['hooks']) {
  $json | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
}

function Is-StaleHook {
  param([string]$Command, [string]$NewCommand)
  if ($Command -eq $NewCommand) { return $true }
  if ($Command -match 'notify-pi\.ps1') { return $true }
  if ($Command -match 'idle-pi\.ps1')   { return $true }
  return $false
}

function Install-Hook {
  param(
    [string]$EventName,
    [string]$Sub,
    [string]$Matcher = $null
  )

  $newCmd = "$hookBase $Sub"

  if (-not $json.hooks.PSObject.Properties[$EventName]) {
    $json.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @()
  }

  $cleanMatchers = @()
  foreach ($matcher in @($json.hooks.$EventName)) {
    $keepHooks = @()
    foreach ($hook in @($matcher.hooks)) {
      if (-not (Is-StaleHook -Command $hook.command -NewCommand $newCmd)) {
        $keepHooks += $hook
      }
    }
    if ($keepHooks.Count -gt 0) {
      $matcher.hooks = $keepHooks
      $cleanMatchers += $matcher
    }
  }

  $entry = [PSCustomObject]@{
    hooks = @(
      [PSCustomObject]@{
        type    = 'command'
        shell   = 'powershell'
        command = $newCmd
      }
    )
  }
  if ($Matcher) {
    $entry | Add-Member -NotePropertyName 'matcher' -NotePropertyValue $Matcher
  }
  $cleanMatchers += $entry
  $json.hooks.$EventName = $cleanMatchers
}

Install-Hook -EventName 'Notification'     -Sub 'notify'
Install-Hook -EventName 'Stop'             -Sub 'notify'
Install-Hook -EventName 'UserPromptSubmit' -Sub 'idle'
# SessionEnd requires a matcher or it silently does not fire — use a wildcard
# regex so we catch every why_session_ended reason (/exit, /clear, logout, ...)
Install-Hook -EventName 'SessionEnd'       -Sub 'end'      -Matcher '.*'
Install-Hook -EventName 'SessionStart'     -Sub 'heartbeat'
Install-Hook -EventName 'PreToolUse'       -Sub 'heartbeat'
Install-Hook -EventName 'PostToolUse'      -Sub 'heartbeat'

$json | ConvertTo-Json -Depth 32 | Set-Content -Path $Settings -Encoding UTF8
Write-Host "Merged hook entries into $Settings (backup: $backup)"
Write-Host ""
Write-Host "Done. Restart Claude Code (or open /hooks) to pick up the new hooks."
