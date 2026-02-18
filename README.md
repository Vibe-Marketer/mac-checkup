# Mac Health Checkup

**Free, open-source Mac diagnostic tool. Battery health, performance, storage cleanup, and optimization — no AI, no accounts, 100% local.**

Your Mac deserves a checkup. Mac Health Checkup runs a full diagnostic on your machine in seconds — battery condition, storage waste, resource hogs, startup bloat, and more — all without sending a single byte of data off your computer.

---

## Features

- **Battery Diagnostics** — Health percentage, cycle count, charging status, temperature, and cell balance. Know exactly how your battery is doing, not just what the menu bar icon says.
- **Resource Hog Detection** — Find the apps eating your CPU and RAM. Get suggestions for lightweight alternatives to known heavy hitters.
- **Storage Analysis with Interactive Cleanup** — Scan for caches, system logs, browser data, old downloads, developer caches, and Trash. See exactly what is taking up space, then choose what to remove.
- **Unused App Finder** — Discover apps you haven't opened in months (or ever) that are sitting on your drive.
- **Startup Item Audit** — See what launches every time you boot up and what you can safely disable.
- **SSD Health Check** — Monitor your drive's condition so you are never caught off guard by a failing disk.
- **Optimization Recommendations** — Actionable tips tailored to your system's current state.
- **Stats App Integration** — Works alongside the free [Stats](https://github.com/exelban/stats) menu bar app for real-time monitoring.

---

## Quick Install

### Option 1: Download the App

> Download the latest `.dmg` from the [Releases](https://github.com/naegele/mac-checkup/releases) page. Open it, drag to Applications, and double-click to run.

### Option 2: Homebrew (coming soon)

```bash
brew install --cask mac-checkup
```

### Option 3: One-liner (Terminal)

```bash
curl -sL https://raw.githubusercontent.com/naegele/mac-checkup/main/mac-checkup.sh -o /usr/local/bin/mac-checkup && chmod +x /usr/local/bin/mac-checkup
```

---

## Usage

**From the app:**
Double-click **Mac Health Checkup** in your Applications folder (or wherever you saved it). A Terminal window will open and the checkup will run automatically.

**From Terminal:**

```bash
mac-checkup
```

That's it. The report prints directly in your terminal — no windows, no logins, no nonsense.

---

## Screenshots

> _Screenshots coming soon._

---

## How It Works

Mac Health Checkup does not install any background processes, daemons, or kernel extensions. It is a shell script that calls built-in macOS commands you already have on your system:

| Command | What it checks |
|---|---|
| `pmset` | Battery status, power settings |
| `ioreg` | Battery health, cycle count, cell voltage, temperature |
| `system_profiler` | Hardware info, storage details, app list |
| `ps` | Running processes, CPU and memory usage |
| `du` | Disk usage for caches, logs, and other directories |
| `defaults` | Application last-opened dates, startup items |
| `diskutil` | SSD health and SMART status |
| `launchctl` | Launch agents and daemons |

Everything runs locally. Nothing is uploaded, phoned home, or shared. The source code is right here — read every line if you want.

---

## Requirements

- **macOS 10.15+** (Catalina or later)
- Works on both **Intel** and **Apple Silicon** Macs
- No dependencies — uses only built-in macOS tools

---

## License

[MIT License](LICENSE) — Copyright 2026 Naegele

Use it, modify it, share it, sell it. Just keep the license notice.

---

## Background

This project was inspired by years of running a cell phone repair shop. Customers would come in with slow phones, dying batteries, and full storage — problems that were almost always fixable with the right information. Most people just didn't have an easy way to see what was going on inside their device.

Mac Health Checkup brings that same idea to your laptop. No upsells, no subscriptions, no data harvesting. Just a straightforward look at how your Mac is doing and what you can do about it.

---

_Built with care. No telemetry. No tracking. Just a checkup._
