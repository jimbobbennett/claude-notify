# Claude Code hook -> tells the Pi to dance. Forwards the basename of the
# current Claude Code working directory as the "session" name so the Pi can
# show which Claude is asking.
$ErrorActionPreference = 'SilentlyContinue'
$url = if ($env:CLAUDE_NOTIFY_URL) { $env:CLAUDE_NOTIFY_URL } else { 'http://claude-notify.local:8080' }
$raw = [Console]::In.ReadToEnd()
$session = ''
$message = ''
try {
  $obj = $raw | ConvertFrom-Json
  if ($obj.cwd)     { $session = Split-Path $obj.cwd -Leaf }
  if ($obj.message) { $message = $obj.message }
} catch {}
$body = @{ session = $session; message = $message } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri "$url/notify" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 2 | Out-Null
exit 0
