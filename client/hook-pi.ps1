# Claude Notify universal hook for Windows / PowerShell.
#
# Usage: hook-pi.ps1 {notify|idle|heartbeat|end}
#
# Reads Claude Code's hook payload on stdin, forwards session_id +
# label + (for heartbeats) a random whimsy word to the Pi.
param([string]$Cmd = 'notify')

$ErrorActionPreference = 'SilentlyContinue'

$url = if ($env:CLAUDE_NOTIFY_URL) { $env:CLAUDE_NOTIFY_URL } else { 'http://claude-notify.local:8080' }

switch ($Cmd) {
  'notify'    { $endpoint = '/notify' }
  'idle'      { $endpoint = '/idle' }
  'heartbeat' { $endpoint = '/heartbeat' }
  'end'       { $endpoint = '/end' }
  default     { exit 0 }
}

$raw = [Console]::In.ReadToEnd()
$sessionId = ''
$label = ''
$message = ''
try {
  $obj = $raw | ConvertFrom-Json
  if ($obj.session_id) { $sessionId = $obj.session_id }
  if ($obj.cwd)        { $label = Split-Path $obj.cwd -Leaf }
  if ($obj.message)    { $message = $obj.message }
} catch {}

$activity = ''
if ($Cmd -eq 'heartbeat') {
  $words = @(
    'Pondering','Frobnicating','Discombobulating','Cogitating','Ruminating',
    'Contemplating','Wrangling','Tinkering','Concocting','Untangling',
    'Brewing','Hatching','Marinating','Mulling','Plotting',
    'Scheming','Synthesizing','Reticulating','Befuddling','Conjuring',
    'Crafting','Stewing','Percolating','Cerebrating','Hornswoggling',
    'Whittling','Noodling','Tessellating','Bamboozling','Confabulating',
    'Massaging','Calibrating','Wrastling','Galumphing','Snurgling'
  )
  $activity = Get-Random -InputObject $words
}

$body = @{
  session_id = $sessionId
  label      = $label
  message    = $message
  activity   = $activity
} | ConvertTo-Json -Compress

Invoke-RestMethod -Uri "$url$endpoint" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 2 | Out-Null
exit 0
