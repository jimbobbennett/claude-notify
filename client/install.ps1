# Claude Notify installer — native Windows / PowerShell.
#
# Copies notify-pi.ps1 and idle-pi.ps1 into %USERPROFILE%\.claude\hooks\ and
# merges the four hook entries (Notification, Stop, UserPromptSubmit,
# SessionEnd) into %USERPROFILE%\.claude\settings.json. Safe to re-run.
#
# Requires PowerShell 5.1+ (Windows 10/11 default). PowerShell 7+ recommended.
[CmdletBinding()]
param(
  [string]$Url,
  [string]$Settings = (Join-Path $env:USERPROFILE '.claude\settings.json')
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hooksDir  = Join-Path $claudeDir 'hooks'

# 1. Copy hook scripts.
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
Copy-Item -Force (Join-Path $scriptDir 'notify-pi.ps1') $hooksDir
Copy-Item -Force (Join-Path $scriptDir 'idle-pi.ps1')   $hooksDir
Write-Host "Installed hook scripts to $hooksDir"

# 2. Persist CLAUDE_NOTIFY_URL if requested.
if ($Url) {
  [Environment]::SetEnvironmentVariable('CLAUDE_NOTIFY_URL', $Url, 'User')
  Write-Host "Set CLAUDE_NOTIFY_URL=$Url for the current user (open a new shell to pick it up)"
}

# 3. Merge hook entries into settings.json.
$notifyCmd = '& "$env:USERPROFILE\.claude\hooks\notify-pi.ps1"'
$idleCmd   = '& "$env:USERPROFILE\.claude\hooks\idle-pi.ps1"'

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

function Add-Hook {
  param([string]$EventName, [string]$Cmd)

  if (-not $json.hooks.PSObject.Properties[$EventName]) {
    $json.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @()
  }
  $arr = @($json.hooks.$EventName)
  foreach ($matcher in $arr) {
    if ($matcher.hooks) {
      foreach ($hook in $matcher.hooks) {
        if ($hook.command -eq $Cmd) { return }
      }
    }
  }
  $arr += [PSCustomObject]@{
    hooks = @(
      [PSCustomObject]@{
        type    = 'command'
        shell   = 'powershell'
        command = $Cmd
      }
    )
  }
  $json.hooks.$EventName = $arr
}

Add-Hook -EventName 'Notification'     -Cmd $notifyCmd
Add-Hook -EventName 'Stop'             -Cmd $notifyCmd
Add-Hook -EventName 'UserPromptSubmit' -Cmd $idleCmd
Add-Hook -EventName 'SessionEnd'       -Cmd $idleCmd

$json | ConvertTo-Json -Depth 32 | Set-Content -Path $Settings -Encoding UTF8
Write-Host "Merged hook entries into $Settings (backup: $backup)"
Write-Host ""
Write-Host "Done. Restart Claude Code (or open /hooks) to pick up the new hooks."
