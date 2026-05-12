# Claude Notify

A little Claude character that lives on a Raspberry Pi's touchscreen and dances
whenever Claude Code on your Mac, Linux box, or Windows machine is waiting for
your input.

| Idle / bored | Dancing (input needed) |
| --- | --- |
| ![](docs/idle.png) | ![](docs/dancing.gif) |

When you're heads-down in another window and Claude Code is sitting there asking
"can I run this command?" or "what next?", the Pi spots it via a hook and the
little character springs to life with the name of the project that's waiting.

---

## How it works

```
┌──────────────────────────┐                  ┌──────────────────────────────┐
│ Mac / Linux / Windows    │                  │  Raspberry Pi @ host.local   │
│ running Claude Code      │                  │                              │
│                          │                  │  Flask server on :8080       │
│  ~/.claude/settings.json │                  │   ├─ POST /notify  → dance   │
│   ├─ Notification    ────┼──┐               │   ├─ POST /idle    → bored   │
│   ├─ Stop            ────┼──┤               │   ├─ POST /heartbeat → tick  │
│   ├─ UserPromptSubmit ───┼──┤               │   ├─ POST /end     → remove  │
│   ├─ SessionStart    ────┼──┼── HTTP POST ─►│   └─ GET  /events  (SSE)     │
│   ├─ SessionEnd      ────┼──┤               │                              │
│   ├─ PreToolUse      ────┼──┤               │  Chromium kiosk → index.html │
│   └─ PostToolUse     ────┼──┘               │   └─ Grid of SVG mascots,    │
│                          │                  │      one per Claude session  │
│  ~/.claude/hooks/        │                  │                              │
│   └─ hook-pi.sh / .ps1   │                  │                              │
└──────────────────────────┘                  └──────────────────────────────┘
```

Each Claude Code session is tracked separately on the Pi by its `session_id`,
so multiple Claudes running in parallel get their own mascot in a small grid
(up to 4 visible at once, dancing ones bubble to the front).

Seven Claude Code [hook events](https://docs.anthropic.com/en/docs/claude-code/hooks)
are wired up, all to a single `hook-pi` script with a subcommand:

| Hook | Subcommand | Pi action |
| --- | --- | --- |
| `Notification` | `notify` | That session's mascot starts dancing |
| `Stop` | `notify` | That session's mascot starts dancing |
| `UserPromptSubmit` | `idle` | Back to bored |
| `SessionEnd` | `end` | Remove the mascot from the grid |
| `SessionStart` | `heartbeat` | Add the mascot to the grid (idle) |
| `PreToolUse` | `heartbeat` | Keep alive + show a whimsy word ("Frobnicating…") |
| `PostToolUse` | `heartbeat` | Same as above |

`PreToolUse` and `PostToolUse` are pure heartbeats — they fire continuously
while Claude is working through tool calls, refreshing the session's
"last seen" timestamp and (optionally) updating the whimsy activity word.
After 10 minutes with no hook activity at all, the mascot is evicted. Hard
kills (closing the terminal, `kill -9`) don't fire `SessionEnd`, so this
eviction is the safety net.

The Pi runs a tiny Flask server that holds per-session state and streams
snapshots to the browser via Server-Sent Events. The browser is Chromium in
kiosk mode rendering a grid of SVG mascots with CSS keyframe animations.

---

## Hardware

This was built for a **Waveshare-style 3.5" SPI touchscreen** (the `tft35a`
overlay, 480×320 resolution), but anything that gives the Pi a framebuffer
will work — you'll just want to tweak the CSS for different aspect ratios.

What you need:

- A Raspberry Pi (Zero 2 W, 3, 4, or 5 — anything that can run Pi OS Desktop).
- A microSD card (8 GB+).
- A **3.5" SPI LCD** that uses the GoodTFT / Waveshare driver tree. The
  cheap eBay/AliExpress 320×480 boards branded "MPI3508" or "Waveshare 3.5
  RPi LCD (A)" generally work with this driver.
- Power supply for the Pi.
- A Mac (or any computer running Claude Code) on the same LAN as the Pi.

---

## Pi-side install (start to finish)

These instructions assume a fresh microSD card. If your Pi is already running
with the LCD working, skip to step 4.

### 1. Flash Raspberry Pi OS

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
Pick **Raspberry Pi OS (64-bit) — Desktop**.

In the imager's settings cog (or `Ctrl+Shift+X`), pre-configure:

- **Hostname:** `claude-notify` (this is what the Mac will talk to — if you
  pick something else, update the URL on the Mac side accordingly).
- **Username/password:** anything you like. The examples below assume
  username `jim`; substitute yours.
- **Wi-Fi:** join the same network as the Mac.
- **SSH:** enabled, public-key auth recommended.
- **Locale / keyboard:** whatever you prefer.

Flash the card, plug it into the Pi, power on. Give it a couple of minutes to
do the first-boot resize. SSH in once:

```sh
ssh jim@claude-notify.local
```

### 2. Enable auto-login to desktop

For the kiosk to start automatically the Pi needs to boot straight into a
graphical session as your user, no password prompt.

```sh
sudo raspi-config
```

In `1 System Options → S5 Boot / Auto Login`, pick **Desktop Autologin**.
Reboot.

### 3. Install the 3.5" LCD driver

The screen needs a kernel overlay (`tft35a`) plus an `fbcp` userspace mirror
to show the regular HDMI framebuffer on the SPI panel. The easiest path is
the community [`goodtft/LCD-show`](https://github.com/goodtft/LCD-show)
repo:

```sh
cd ~
git clone https://github.com/goodtft/LCD-show.git
chmod -R 755 LCD-show
cd LCD-show
sudo ./LCD35-show
```

That script edits `/boot/firmware/config.txt`, swaps to an X11 session
(the kiosk relies on X11, not Wayland), forces `hdmi_cvt 320 480 60 6 0 0 0`,
and reboots.

**After the reboot the screen will be in portrait (320 wide × 480 tall).**
This app is designed for **landscape (480 wide × 320 tall)** because that's
nicer for the mascot's wide arms. Rotate the framebuffer by editing
`/boot/firmware/config.txt`:

```
dtoverlay=tft35a:rotate=90
```

(Use `0`, `90`, `180`, or `270` — pick whichever orientation looks right when
the Pi is on your desk.) Reboot once more.

Verify by SSHing in and running:

```sh
DISPLAY=:0 xrandr | head -2
```

You should see `current 480 x 320` (or matching your rotation).

### 4. Install Claude Notify

```sh
cd ~
git clone https://github.com/jimbobbennett/claude-notify.git
cp -r claude-notify/pi ~/claude-notify-app    # avoid name clash with this repo dir
# OR if you prefer to work from the cloned repo directly:
#   keep the repo where it is and adjust the paths in start-kiosk.sh

# Use whichever layout you picked above. The autostart files assume
# the runtime lives at ~/claude-notify/, so set up a symlink or copy:
ln -snf ~/claude-notify-app ~/claude-notify
```

If you want to keep things simple, just clone the repo's `pi/` contents
straight into `~/claude-notify/`:

```sh
mkdir -p ~/claude-notify
cp -r claude-notify/pi/. ~/claude-notify/
chmod +x ~/claude-notify/start-kiosk.sh
```

Python and Flask are usually pre-installed on Pi OS Desktop. Confirm:

```sh
python3 -c 'import flask; print(flask.__version__)'
```

If Flask is missing:

```sh
sudo apt update
sudo apt install -y python3-flask
```

### 5. Test the server manually

```sh
cd ~/claude-notify
python3 server.py
```

From any machine on the same LAN:

```sh
curl http://claude-notify.local:8080/state
# {"message":"","seq":0,"session":"","state":"idle"}

curl -X POST http://claude-notify.local:8080/notify
# {"message":"","seq":1,"session":"","state":"dancing"}
```

Open `http://claude-notify.local:8080/` in your browser and you should see
the mascot. Tap (or click) once to toggle states for a quick smoke test.

`Ctrl-C` the server when you're satisfied.

### 6. Install the autostart entry

When you log in to the desktop, LXDE's autostart directory runs every
`.desktop` file it finds. Drop the supplied one in:

```sh
mkdir -p ~/.config/autostart
cp ~/claude-notify/claude-notify-kiosk.desktop ~/.config/autostart/
```

The `.desktop` file just calls `~/claude-notify/start-kiosk.sh`, which:

- Waits for the X server to come up (`xset q`).
- Disables screen blanking and DPMS.
- Starts the Flask server if it isn't already running.
- Launches Chromium in kiosk/`--app` mode pointed at `http://localhost:8080`.
- Restarts Chromium if it dies, with **exponential backoff** and a long
  cool-down after repeated fast failures so a broken environment can't pin
  the Pi's CPU.

Reboot:

```sh
sudo reboot
```

When the Pi comes back you should see the character idling on the LCD.

### Optional: hide the cursor

```sh
sudo apt install -y unclutter
```

`start-kiosk.sh` picks `unclutter` up automatically if present.

---

## Client-side install (macOS, Linux, Windows)

The "client" is whatever machine runs Claude Code. The supplied hook
scripts are plain POSIX shell — they work as-is on **macOS**, **Linux**,
and on **Windows under WSL or Git Bash**. Windows users who prefer native
PowerShell can use the inline alternative further down.

### Prerequisites

Both scripts use `curl` (everywhere by default) and `jq` (to extract the
`cwd` field from Claude Code's hook payload). `jq` is optional — without
it the Pi still dances, it just won't show the session label.

| OS | Install `jq` |
| --- | --- |
| macOS | `brew install jq` (often already present) |
| Debian / Ubuntu / Raspberry Pi OS | `sudo apt install jq` |
| Fedora / RHEL | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |
| Windows (winget) | `winget install jqlang.jq` |
| Windows (scoop) | `scoop install jq` |
| Windows (choco) | `choco install jq` |

### Claude Code settings location

Claude Code reads its user-level settings from the same path on every
platform — your home directory. Below, `~` and `$HOME` mean:

| OS | `$HOME` resolves to |
| --- | --- |
| macOS | `/Users/<you>` |
| Linux | `/home/<you>` |
| Windows (Git Bash / WSL) | `/c/Users/<you>` or your WSL `$HOME` |
| Windows (PowerShell) | `$env:USERPROFILE` (e.g. `C:\Users\<you>`) |

Settings file: `~/.claude/settings.json`. Hooks directory:
`~/.claude/hooks/`. Both are created on first use if they don't exist.

### Quick install (recommended)

The repo ships with installers that copy the hook scripts and merge the
four hook entries into `settings.json` for you. They're safe to re-run
(idempotent) and preserve any existing hooks you have.

#### macOS / Linux / WSL / Git Bash

```sh
./client/install.sh
# or, with a non-default Pi URL:
./client/install.sh --url http://192.168.1.42:8080
```

Requires `jq` to merge JSON safely. If it's missing, the installer
prints the block to paste in manually. See the prerequisites table for
how to install `jq` on your OS.

#### Windows (native PowerShell)

```powershell
.\client\install.ps1
# or, with a non-default Pi URL:
.\client\install.ps1 -Url http://192.168.1.42:8080
```

If PowerShell refuses to run the script, allow it for the current
session with:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Both installers:

- copy the hook scripts to `~/.claude/hooks/`
- back up your existing `settings.json` (as `settings.json.bak.<timestamp>`)
- add four hook entries (`Notification`, `Stop`, `UserPromptSubmit`,
  `SessionEnd`), leaving anything else in the file untouched
- skip an entry if your command is already wired in, so re-running is safe

After the installer finishes, **restart Claude Code** (or open `/hooks`)
to pick up the new hooks. Skip ahead to [Customization](#customization).

### Manual install

If you'd rather wire things up by hand, follow the two steps below.

#### 1. Copy the hook script

**macOS / Linux / WSL / Git Bash:**

```sh
mkdir -p ~/.claude/hooks
cp client/hook-pi.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/hook-pi.sh
```

Quick test:

```sh
echo '{"session_id":"abc","cwd":"/path/to/some-project"}' \
  | ~/.claude/hooks/hook-pi.sh notify
sleep 1
curl http://claude-notify.local:8080/state
# {"sessions":{"abc":{"state":"dancing","label":"some-project", ...}}, ...}
```

**Windows (native PowerShell):**

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\hooks" | Out-Null
Copy-Item client\hook-pi.ps1 "$env:USERPROFILE\.claude\hooks\"
```

Quick test:

```powershell
'{"session_id":"abc","cwd":"C:\\Users\\you\\some-project"}' `
  | & "$env:USERPROFILE\.claude\hooks\hook-pi.ps1" notify
Start-Sleep 1
Invoke-RestMethod http://claude-notify.local:8080/state
```

#### Overriding the Pi URL

If your Pi isn't at `claude-notify.local`, set `CLAUDE_NOTIFY_URL` to its
address. The scripts pick it up from the environment. (The quick
installer handles this for you via `--url` / `-Url`.)

| Shell | Persistent override |
| --- | --- |
| bash / zsh (macOS, Linux, Git Bash, WSL) | `echo 'export CLAUDE_NOTIFY_URL=http://192.168.1.42:8080' >> ~/.bashrc` (or `~/.zshrc`) |
| fish | `set -Ux CLAUDE_NOTIFY_URL http://192.168.1.42:8080` |
| PowerShell | `[Environment]::SetEnvironmentVariable('CLAUDE_NOTIFY_URL','http://192.168.1.42:8080','User')` |

You can also just edit the URL in the script files directly.

#### 2. Wire the hooks into Claude Code

Edit `~/.claude/settings.json` (or `%USERPROFILE%\.claude\settings.json`
on Windows) and add a `hooks` block. Merge with any existing keys.
**Seven hook events all point at the same `hook-pi` script with a
subcommand** — strongly consider just using the installer; the manual
JSON below is verbose.

**macOS / Linux / WSL / Git Bash** — Claude Code's default shell on these
platforms is bash, so `$HOME` expands correctly:

```json
{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh notify"    }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh notify"    }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh idle"      }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh end"       }] }],
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh heartbeat" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh heartbeat" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/hook-pi.sh heartbeat" }] }]
  }
}
```

**Native Windows (PowerShell variant)** — add `"shell": "powershell"` to
each hook entry and point at the `.ps1` file:

```json
{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" notify"    }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" notify"    }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" idle"      }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" end"       }] }],
    "SessionStart":     [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" heartbeat" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" heartbeat" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "shell": "powershell", "command": "& \"$env:USERPROFILE\\.claude\\hooks\\hook-pi.ps1\" heartbeat" }] }]
  }
}
```

Restart Claude Code (or open the `/hooks` menu once to force a reload —
Claude Code only watches files that existed when the session started).

That's it. Open any project, ask Claude to do something that needs
permission, and the Pi should light up.

---

## Customization

- **Different host / port:** pass `--url` / `-Url` to the installer, set
  `CLAUDE_NOTIFY_URL` in your shell env, or edit the default URL in
  `client/hook-pi.sh` / `client/hook-pi.ps1`.
- **Different session label:** the script forwards `cwd` basename by
  default. Edit the `jq` expression in `client/hook-pi.sh` to send
  something else — e.g. `.session_id` or a fixed string. In the
  PowerShell version, change the `Split-Path $obj.cwd -Leaf` line.
- **Whimsy word list:** add, remove, or replace the words in the awk
  string in `client/hook-pi.sh` (`$words` array in `hook-pi.ps1`). The
  Pi shows whichever word the most recent `PreToolUse` / `PostToolUse`
  picked.
- **Eviction timeout:** if a Claude session goes silent (hard kill, crash),
  the mascot disappears after 10 minutes. Tune `IDLE_EVICT_SECONDS` in
  `pi/server.py`. The activity word clears after `ACTIVITY_TIMEOUT`
  seconds (default 10) of no heartbeat.
- **Number of visible mascots:** the frontend shows the top 4 sessions
  (dancing first, then idle). Tune `MAX_VISIBLE` in `pi/static/app.js`
  and adjust the `.grid[data-count="..."]` rules in `pi/static/style.css`.
- **Mascot / colours / animations:** all in `pi/static/style.css` and
  `pi/static/index.html`. Push the changed file with `scp` and kill
  Chromium — the kiosk loop reloads it within a few seconds.
- **Sound:** Chromium can play `<audio>`. Drop a chime in `pi/static/`,
  reference it in `index.html`, and play it on state change in `app.js`.

---

## Troubleshooting

**Pi screen is white / blank after boot.**
Usually a Chromium profile that crashed previously. Wipe it:

```sh
rm -rf ~/.config/claude-notify-chromium
~/claude-notify/start-kiosk.sh    # or just reboot
```

**Screen orientation is wrong.**
Edit `/boot/firmware/config.txt` and change `dtoverlay=tft35a:rotate=N` to
`0`, `90`, `180`, or `270`. Reboot.

**Hooks aren't firing.**
Claude Code only watches settings files that existed when the session
started. Either restart Claude Code or open `/hooks` to force a reload.
Test the hook scripts directly first:

```sh
echo '{"session_id":"test","cwd":"/tmp/test"}' \
  | ~/.claude/hooks/hook-pi.sh notify
sleep 1
curl http://claude-notify.local:8080/state
```

**`curl` sometimes times out resolving `claude-notify.local`.**
mDNS resolvers can get cranky. The Pi is still reachable — try the raw
IP, then flush the cache:

- macOS: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`
- Linux: `sudo systemctl restart avahi-daemon` (if installed)
- Windows: `ipconfig /flushdns`

If `.local` resolution doesn't work on Windows at all, install
[Bonjour Print Services](https://support.apple.com/kb/DL999) or just
hard-code the Pi's IP via `CLAUDE_NOTIFY_URL`.

**Animation is jerky.**
Chromium is software-rendering on the Pi (most small SPI LCDs can't
hardware-accelerate). The supplied CSS already drops the expensive bits
(filter-based pulses, per-element wiggles). If you add more, prefer
`transform`-only keyframes and `will-change: transform` on the animated
element.

**Pi seems to lock up.**
Check `~/claude-notify/logs/kiosk.log` after reboot. The hardened
`start-kiosk.sh` logs every Chromium launch and cool-down. Repeated
"fast failure" entries point at an environment problem (no X, bad GPU
options, etc.) rather than a code bug.

**Logs in general.**
Everything lands in `~/claude-notify/logs/`:

- `kiosk.log` — what the autostart script is doing.
- `server.log` — Flask stdout/stderr.
- `chromium.log` — Chromium stderr (capped at 256 KB).

---

## Repo layout

```
.
├── pi/
│   ├── server.py                       # Flask server with /notify, /idle, /events
│   ├── start-kiosk.sh                  # Autostart entry point (hardened)
│   ├── claude-notify-kiosk.desktop     # LXDE autostart file
│   └── static/
│       ├── index.html                  # Grid container + card <template>
│       ├── style.css                   # Grid layout, bob/bored/dance keyframes
│       └── app.js                      # SSE client, per-session card management
├── client/                             # Hook scripts for the Claude-Code host
│   ├── hook-pi.sh     / hook-pi.ps1    # Universal hook: notify|idle|heartbeat|end
│   ├── install.sh                      # macOS / Linux / WSL / Git Bash installer
│   └── install.ps1                     # Native Windows / PowerShell installer
└── docs/
    ├── idle.png
    └── dancing.png
```

---

## License

MIT — see [`LICENSE`](LICENSE).
