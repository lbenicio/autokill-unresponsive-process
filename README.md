# autokill-unresponsive-process

A macOS background daemon that automatically detects and kills unresponsive GUI applications — the same **"Not Responding"** state shown in Activity Monitor — so you don't have to.

## Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Quick Install](#quick-install)
  - [Manual Install](#manual-install)
- [Usage](#usage)
  - [CLI Options](#cli-options)
  - [Examples](#examples)
- [Configuration](#configuration)
  - [Config File](#config-file)
  - [Environment Variables](#environment-variables)
  - [Exclusion Lists](#exclusion-lists)
- [How Detection Works](#how-detection-works)
- [Kill Strategy](#kill-strategy)
- [Logging](#logging)
- [Managing the Daemon](#managing-the-daemon)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [Security & Privacy](#security--privacy)
- [Project Structure](#project-structure)
- [Building from Source](#building-from-source)
- [License](#license)

---

## How It Works

When a macOS GUI application stops processing events from its run loop, the Window Server flags it as **unresponsive** — this is the "Not Responding" label you see in Activity Monitor and in force-quit dialogs. This daemon continuously monitors for that state and, after a configurable grace period, terminates the offending process.

**The lifecycle for a detected unresponsive process:**

```
Responsive ──→ Unresponsive (detected) ──→ Grace period ──→ SIGTERM ──→ SIGKILL
                     │                          │               │
                     └── Recovers? ─→ cleared   │               └── Didn't exit?
                                                │                   Force kill after
                                                │                   grace-kill timeout
                                                └── Still within
                                                    grace? Wait.
```

1. **Detection** — The daemon scans every 10 seconds (configurable) for GUI apps that the Window Server considers unresponsive.
2. **Grace period** — A newly detected unresponsive app is given 30 seconds (configurable) to recover on its own. If it recovers, it's removed from tracking.
3. **SIGTERM** — If the app is still unresponsive after the grace period, a graceful termination signal is sent.
4. **SIGKILL** — If the app doesn't exit within 10 seconds (configurable) of receiving SIGTERM, it is forcefully killed with SIGKILL.
5. **Notification** — The user receives a macOS notification for each terminated process.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          main.swift                             │
│  Entry point: CLI parsing, signal handlers, GCD timer run loop  │
└──────────────┬───────────────────────────────┬──────────────────┘
               │                               │
               ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────────┐
│     ProcessMonitor       │    │       ProcessKiller           │
│                          │    │                              │
│ • Enumerates GUI apps    │    │ • Sends SIGTERM / SIGKILL    │
│   via NSWorkspace        │    │ • Respects kill cap per      │
│ • Checks responsiveness  │    │   cycle                      │
│   via SkyLight API or    │    │ • Posts macOS notifications   │
│   lsappinfo fallback     │    │   via osascript              │
│ • Tracks state per PID   │    │ • Updates monitor state      │
│ • Enforces grace periods │    │   after acting               │
└──────────┬───────────────┘    └──────────────────────────────┘
           │
           ▼
┌──────────────────────────┐    ┌──────────────────────────────┐
│    Configuration         │    │         Logger               │
│                          │    │                              │
│ • Defaults → config.json │    │ • Apple unified log (os_log) │
│   → env vars → CLI flags │    │ • Rotating file log          │
│ • Exclusion lists        │    │ • Configurable log level     │
│ • Timing parameters      │    │ • 5 MB rotation, 3 backups  │
└──────────────────────────┘    └──────────────────────────────┘
```

### Components

| File | Responsibility |
|---|---|
| `main.swift` | Entry point. Parses CLI arguments, installs UNIX signal handlers (`SIGTERM`, `SIGINT`, `SIGHUP`), sets up a GCD timer on the main queue, and drives the scan-act loop. |
| `ProcessMonitor.swift` | Detects unresponsive GUI applications. Uses the private **SkyLight** framework API (`SLSEventIsAppUnresponsive`) loaded dynamically via `dlopen`/`dlsym` for in-process, low-overhead detection. Falls back to parsing `lsappinfo` output if the private API is unavailable. Maintains per-PID state tracking with timestamps. |
| `ProcessKiller.swift` | Carries out termination decisions. Prefers the Cocoa `NSRunningApplication.terminate()` / `forceTerminate()` API, falling back to raw `kill(2)` syscalls. Posts user-visible notifications via `osascript`. Respects configurable kill caps per scan cycle. |
| `Configuration.swift` | Layered configuration system: built-in defaults → JSON config file → environment variables → CLI flags. Manages exclusion lists for bundle identifiers and process names. |
| `Logger.swift` | Dual-output logger: writes to Apple's unified logging system (`os_log`) and a rotating log file on disk. Supports `DEBUG`, `INFO`, `WARN`, and `ERROR` levels. |

---

## Requirements

- **macOS 13.0 (Ventura)** or later
- **Swift 5.9+** (included with Xcode 15+)
- Xcode or Xcode Command Line Tools (`xcode-select --install`)

---

## Installation

### Quick Install

```sh
git clone <repo-url> autokill-unresponsive-process
cd autokill-unresponsive-process
chmod +x install.sh
./install.sh
```

This will:

1. Build the project in release mode
2. Install the binary to `~/.local/bin/`
3. Install a launchd agent plist to `~/Library/LaunchAgents/`
4. Create a default configuration file at `~/.config/autokill-unresponsive/config.json`
5. Create the log directory at `~/.local/log/autokill-unresponsive/`
6. Start the daemon immediately

### Manual Install

If you prefer to do it step by step:

```sh
# 1. Build
swift build -c release

# 2. Copy the binary
mkdir -p ~/.local/bin
cp .build/release/autokill-unresponsive-process ~/.local/bin/

# 3. Copy and customize the launchd plist
mkdir -p ~/Library/LaunchAgents
sed \
  -e "s|__INSTALL_PATH__|$HOME/.local/bin|g" \
  -e "s|__LOG_DIR__|$HOME/.local/log/autokill-unresponsive|g" \
  com.autokill.unresponsive.plist > ~/Library/LaunchAgents/com.autokill.unresponsive.plist

# 4. Load the agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.autokill.unresponsive.plist
```

---

## Usage

### CLI Options

```
autokill-unresponsive-process [OPTIONS]

OPTIONS:
    -h, --help              Print help message and exit
    -v, --version           Print version and exit
    --dry-run               Log actions without actually killing anything
    --verbose               Enable debug-level logging
    --once                  Run a single scan cycle and exit
    --interval <seconds>    Scan interval (default: 10)
    --grace-term <seconds>  Grace period before SIGTERM (default: 30)
    --grace-kill <seconds>  Grace period before SIGKILL (default: 10)
    --no-notify             Disable macOS user notifications
    --max-kills <count>     Max kills per scan cycle (default: 5)
```

### Examples

**Test mode — single scan, verbose, no kills:**

```sh
autokill-unresponsive-process --once --verbose --dry-run
```

**Run interactively with aggressive settings:**

```sh
autokill-unresponsive-process --verbose --interval 5 --grace-term 15 --grace-kill 5
```

**Run in dry-run mode to observe behavior before committing:**

```sh
autokill-unresponsive-process --dry-run --verbose
```

---

## Configuration

Configuration is resolved in layers (highest precedence first):

1. **CLI flags** (e.g., `--interval 5`)
2. **Environment variables** (e.g., `AUTOKILL_CHECK_INTERVAL=5`)
3. **JSON config file** (`~/.config/autokill-unresponsive/config.json`)
4. **Built-in defaults**

### Config File

Located at `~/.config/autokill-unresponsive/config.json`:

```json
{
    "checkIntervalSeconds": 10,
    "graceBeforeTermSeconds": 30,
    "graceBeforeKillSeconds": 10,
    "dryRun": false,
    "notifyOnKill": true,
    "maxKillsPerCycle": 5,
    "excludedBundleIdentifiers": [
        "com.example.myapp"
    ],
    "excludedProcessNames": [
        "MySpecialApp"
    ]
}
```

> **Note:** Exclusion lists in the config file are **merged** with the built-in exclusions — they don't replace them. You cannot un-exclude a critical system process like Finder or Dock.

To reload configuration while the daemon is running, send `SIGHUP`:

```sh
kill -HUP $(pgrep -x autokill-unresponsive-process)
```

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `AUTOKILL_CHECK_INTERVAL` | `10` | Scan interval in seconds |
| `AUTOKILL_GRACE_TERM` | `30` | Seconds before sending SIGTERM |
| `AUTOKILL_GRACE_KILL` | `10` | Seconds after SIGTERM before SIGKILL |
| `AUTOKILL_DRY_RUN` | `false` | `1`/`true`/`yes` to enable dry-run |
| `AUTOKILL_NOTIFY` | `true` | `0`/`false`/`no` to disable notifications |
| `AUTOKILL_MAX_KILLS` | `5` | Max kills per scan cycle |

### Exclusion Lists

The following system processes are **always** excluded and cannot be killed by the daemon:

| Bundle Identifier | Process Name |
|---|---|
| `com.apple.loginwindow` | loginwindow |
| `com.apple.dock` | Dock |
| `com.apple.finder` | Finder |
| `com.apple.WindowManager` | WindowManager |
| `com.apple.SystemUIServer` | SystemUIServer |
| `com.apple.controlcenter` | Control Center |
| `com.apple.notificationcenterui` | NotificationCenter |
| `com.apple.Spotlight` | Spotlight |
| `com.apple.universalcontrol` | — |
| `com.apple.AirPlayUIAgent` | — |
| `com.apple.TextInputMenuAgent` | — |

You can add your own exclusions via the config file or by modifying the source.

---

## How Detection Works

The daemon uses two detection strategies, tried in order:

### Strategy 1: SkyLight Private API (Primary)

macOS's Window Server tracks whether each GUI app is processing events from its run loop. When an app's main thread is blocked and stops handling events for approximately 5 seconds, the Window Server flags it as unresponsive — this is what Activity Monitor reads.

The daemon dynamically loads the private **SkyLight** framework (the modern successor to CoreGraphics server APIs) and calls:

- `SLSMainConnectionID()` — Gets a connection handle to the Window Server
- `SLSEventIsAppUnresponsive(connectionID, psn)` — Queries whether a specific app is unresponsive

This is the same mechanism Activity Monitor uses. The functions are loaded via `dlopen`/`dlsym` at runtime to avoid linking against private frameworks.

If the SkyLight symbols aren't available (e.g., Apple renamed them in a future macOS version), it falls back to the older `CGSMainConnectionID` / `CGSEventIsAppUnresponsive` names from CoreGraphics.

### Strategy 2: `lsappinfo` Parsing (Fallback)

If neither set of private API symbols can be resolved, the daemon falls back to spawning `lsappinfo info -pid <pid>` for each GUI app and checking the output for `"Not Responding"` or `"Unresponsive"` status labels.

This approach is slower (spawns a subprocess per app per scan) but doesn't depend on private API symbol names remaining stable.

The daemon logs which strategy it's using at startup:

```
ProcessMonitor: using SkyLight private API for responsiveness checks
```

or:

```
ProcessMonitor: SkyLight API unavailable – falling back to lsappinfo
```

### What Counts as a "GUI App"

Only applications with `activationPolicy == .regular` are monitored. These are apps that appear in the Dock — standard GUI applications. Background agents, daemons, and menu bar-only utilities are not scanned.

---

## Kill Strategy

The daemon uses a **progressive escalation** approach:

| Phase | Timing | Signal | Method |
|---|---|---|---|
| **Detection** | t = 0 | — | Process is flagged; grace timer starts |
| **Grace Period** | 0 < t < 30s | — | If the app recovers, tracking is cleared |
| **Graceful Term** | t = 30s | `SIGTERM` | Via `NSRunningApplication.terminate()` first, then `kill(pid, SIGTERM)` as fallback |
| **Force Kill** | t = 40s | `SIGKILL` | Via `NSRunningApplication.forceTerminate()` first, then `kill(pid, SIGKILL)` as fallback |

Using `NSRunningApplication.terminate()` before raw signals gives the app a chance to run Cocoa shutdown hooks (`applicationWillTerminate:`, `atexit` handlers, state restoration saves, etc.).

A **safety cap** of 5 kills per scan cycle (configurable) prevents runaway behavior if many apps become unresponsive simultaneously.

---

## Logging

### Unified System Log

The daemon writes to Apple's unified logging system under:

- **Subsystem:** `com.autokill.unresponsive`
- **Category:** `daemon`

Stream live logs:

```sh
log stream --predicate 'subsystem == "com.autokill.unresponsive"' --level debug
```

Search historical logs:

```sh
log show --predicate 'subsystem == "com.autokill.unresponsive"' --last 1h
```

### File Log

A rotating log file is maintained at:

```
~/.local/log/autokill-unresponsive/autokill.log
```

- **Max file size:** 5 MB
- **Rotation:** Up to 3 rotated backups (`.log.1`, `.log.2`, `.log.3`)
- **Format:** `[timestamp] [LEVEL] [source:line] message`

Tail the log file:

```sh
tail -f ~/.local/log/autokill-unresponsive/autokill.log
```

### launchd Output

stdout and stderr from the launchd-managed process are captured at:

```
~/.local/log/autokill-unresponsive/autokill-launchd-stdout.log
~/.local/log/autokill-unresponsive/autokill-launchd-stderr.log
```

---

## Managing the Daemon

### Check if the daemon is running

```sh
launchctl list com.autokill.unresponsive
```

Or:

```sh
pgrep -x autokill-unresponsive-process
```

### Stop the daemon

```sh
launchctl bootout gui/$(id -u)/com.autokill.unresponsive
```

Or (older macOS):

```sh
launchctl unload ~/Library/LaunchAgents/com.autokill.unresponsive.plist
```

### Start the daemon

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.autokill.unresponsive.plist
```

Or (older macOS):

```sh
launchctl load -w ~/Library/LaunchAgents/com.autokill.unresponsive.plist
```

### Restart the daemon

```sh
launchctl kickstart -k gui/$(id -u)/com.autokill.unresponsive
```

### Reload configuration (without restart)

```sh
kill -HUP $(pgrep -x autokill-unresponsive-process)
```

---

## Troubleshooting

### The daemon isn't starting

1. **Check the plist is valid:**

   ```sh
   plutil -lint ~/Library/LaunchAgents/com.autokill.unresponsive.plist
   ```

2. **Check launchd knows about it:**

   ```sh
   launchctl list | grep autokill
   ```

3. **Check the stderr log for crash output:**

   ```sh
   cat ~/.local/log/autokill-unresponsive/autokill-launchd-stderr.log
   ```

4. **Check the system log for launchd errors:**

   ```sh
   log show --predicate 'process == "launchd" AND eventMessage CONTAINS "autokill"' --last 5m
   ```

### The daemon reports "SkyLight API unavailable"

This is not an error — the daemon will fall back to `lsappinfo` parsing. However, if you want the faster SkyLight detection:

- Make sure you're running a standard macOS installation (not a headless server)
- The binary needs to be run in a GUI session (which it will be as a LaunchAgent)
- Apple may have renamed the private symbols in your macOS version. Check the fallback works correctly via the logs.

### Processes aren't being detected as unresponsive

- Only **regular GUI apps** (those that appear in the Dock) are monitored. Menu bar utilities, background agents, and daemons are excluded by design.
- The "Not Responding" state is determined by the Window Server. A process consuming 100% CPU is **not** necessarily unresponsive — it's only unresponsive if it stops processing window events.
- Run a scan manually to verify: `autokill-unresponsive-process --once --verbose`

### I want to test without killing anything

Use dry-run mode:

```sh
autokill-unresponsive-process --dry-run --verbose --once
```

Or set it permanently in the config:

```json
{
    "dryRun": true
}
```

### An app I need keeps getting killed

Add it to the exclusion list in `~/.config/autokill-unresponsive/config.json`:

```json
{
    "excludedBundleIdentifiers": [
        "com.example.slow-but-important-app"
    ]
}
```

Then reload: `kill -HUP $(pgrep -x autokill-unresponsive-process)`

To find an app's bundle identifier:

```sh
osascript -e 'id of app "App Name"'
```

Or:

```sh
lsappinfo list | grep -B5 "App Name"
```

### Notifications aren't showing up

- The daemon uses `osascript` to display notifications, which may require you to allow notifications from "Script Editor" or "osascript" in **System Settings → Notifications**.
- Disable notification-related issues by running with `--no-notify`.

---

## Uninstallation

### Keep configuration and logs

```sh
./uninstall.sh
```

### Remove everything

```sh
./uninstall.sh --purge
```

This removes:

- The daemon binary (`~/.local/bin/autokill-unresponsive-process`)
- The launchd plist (`~/Library/LaunchAgents/com.autokill.unresponsive.plist`)
- Configuration directory (`~/.config/autokill-unresponsive/`) — only with `--purge`
- Log directory (`~/.local/log/autokill-unresponsive/`) — only with `--purge`

---

## Security & Privacy

- **No elevated privileges required.** The daemon runs as a regular user-level LaunchAgent. It can only kill processes owned by the current user.
- **No network access.** The daemon is entirely local and makes no network connections.
- **No private data access.** It only reads process metadata (PID, bundle ID, name, responsiveness state).
- **Private API usage.** The SkyLight framework functions are private Apple APIs. They are loaded dynamically and the daemon gracefully falls back to `lsappinfo` if they're unavailable. Private API usage means behavior could change across macOS updates — always test after upgrading macOS.
- **Accessibility permissions.** On some macOS configurations, you may be prompted to grant Accessibility permissions. This is required for sending Apple Events (used by the notification system via `osascript`). The core detection and kill functionality works without Accessibility permissions.

---

## Project Structure

```
autokill-unresponsive-process/
├── Package.swift                              # Swift Package Manager manifest
├── README.md                                  # This file
├── Sources/
│   └── autokill-unresponsive-process/
│       ├── main.swift                         # Entry point & daemon run loop
│       ├── ProcessMonitor.swift               # Unresponsive app detection
│       ├── ProcessKiller.swift                # Kill logic & notifications
│       ├── Configuration.swift                # Layered config system
│       └── Logger.swift                       # Dual-output logger
├── com.autokill.unresponsive.plist            # launchd agent template
├── install.sh                                 # Build + install + register
└── uninstall.sh                               # Stop + remove + clean
```

---

## Building from Source

```sh
# Debug build
swift build

# Release build (optimized)
swift build -c release

# Run directly without installing
swift run autokill-unresponsive-process --once --verbose --dry-run

# Run tests (if added)
swift test
```

The project targets **macOS 13+** and uses the private SkyLight framework for responsiveness checks. The linker flag `-F/System/Library/PrivateFrameworks` is included in `Package.swift` but the framework is loaded dynamically at runtime — the build will succeed even if the framework isn't directly linkable.

---

## License

MIT