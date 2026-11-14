<p align="center">
  <img src="docs/images/hero.png" alt="Tacho — the menu bar and detail panels for CPU, battery and memory" width="100%">
</p>

<p align="center">
  <img src="docs/images/icon.png" alt="Tacho icon" width="128">
</p>

<h1 align="center">Tacho</h1>

<p align="center">
  <b>Gauges for your Mac — in the menu bar and in the notch.</b><br>
  CPU, temperature, fans, GPU, memory, disk, network, battery, Docker and Kubernetes — and your Claude Code and Codex limits.
</p>

<p align="center">
  <a href="https://github.com/hieupnvmg/Tacho/releases/latest/download/Tacho.dmg"><b>⬇︎ Download Tacho for macOS</b></a>
  &nbsp;·&nbsp; or <a href="#install">install with Homebrew</a>
  <br>free &nbsp;·&nbsp; Apple silicon Macs, macOS 13 or later
</p>

<p align="center">
  <b>English</b> &nbsp;·&nbsp; <a href="README.vi.md">Tiếng Việt</a>
</p>

---

## At a glance

| | |
|---|---|
| **Menu bar** | CPU, GPU, memory, disk, network, connection, battery — each with a live graph, or all in one compact item |
| **Panels** | Click a reading for details: heaviest apps, apps using the network, speed test, battery health, accessory batteries |
| **The notch** | Short alerts in its "wings", and a control panel when you rest the pointer on it: music, outputs, calls, meetings, files, clipboard, AI limits |
| **Developer tools** | Claude Code and Codex limits and tokens, Docker containers and the Kubernetes context |
| **CPU runner** | A cat (or your own animation) that runs faster the busier the CPU is |
| **The window** | Overview, CPU, memory, disk, battery, network, 24-hour history and every process |
| **Alerts** | A hot CPU, low battery, a nearly full disk, no Internet — as notifications or in the notch |
| **Languages** | English, Tiếng Việt, Русский |

## Everything in the menu bar

Each reading is its own item with a live graph. Click one for the details, no window needed.

<p align="center">
  <img src="docs/images/popovers.png" alt="Network, disk and connection panels" width="100%">
</p>

- **CPU and GPU** — load, temperature (amber when warm, red when hot), and the five heaviest apps, with
  helper processes (like Chrome's renderers) added to the app they belong to
- **Memory** — memory pressure, the way Activity Monitor colours it, and the apps using the most
- **Network** — upload and download speed, whether you're online through Wi-Fi, Ethernet or a VPN,
  **which apps are using the network right now**, and a **one-click speed test** that says whether the
  connection is good enough for video calls
- **Connection** — a dot for Internet access, your public and local IP, click to copy
- **Disk** — read and write speed, and free space
- **Battery** — charge, time to full or to empty, charger power, and your mouse, keyboard and AirPods
- **Compact mode** — every reading in one small item, made for MacBooks with a notch
- **Docker and Kubernetes** — running containers, and a ⎈ that turns **red when the Kubernetes context
  is production**. Its panel starts or quits Docker Desktop (or OrbStack), starts and stops containers,
  and shows how much RAM Docker and each container use
- **CPU runner** — a cat, a dog, a coffee cup, an engine… runs in the menu bar, faster the busier the
  CPU. Eight come built in, or import your own from PNG frames (runners from the
  [Runner Gallery](https://runcat-dev.github.io/RunnerGallery/) work as they are)
- **Activity Monitor** is one click away from every panel

## A notch that talks

The notch on a MacBook usually sits there doing nothing. Tacho has it spread its wings for a few
seconds when something happens, and opens a small control panel when you rest the pointer on it.

<p align="center">
  <img src="docs/images/notch-events.png" alt="The notch warning about an app hogging the CPU, a meeting about to start, and glowing red while the screen is shared" width="70%">
</p>

**The notch tells you when:**

- the charger goes in or out, or the battery reaches 20% and 10%
- AirPods, a mouse or a keyboard connect
- the connection drops or comes back, a VPN comes up or drops, or your public IP changes
- a call starts or ends — and **while you share your screen** it keeps a red glow so you don't forget
- an app hogs the CPU, the CPU runs hot, or memory runs out
- a meeting is 5 minutes away, and when it starts
- a Claude Code or Codex limit passes 80% and 95%

**Rest the pointer on the notch to:**

- control what's playing in any app (YouTube, Spotify, Music…) and pick the speakers or headphones
- see the Teams, Zoom… call in progress, **mute the mic**, see whether the camera is on, and bring the
  call window back
- **join the next meeting** with one button — meetings come from the Mac's Calendar, including Teams
  meetings from a Microsoft 365 account
- **quit the app** that's hogging the CPU, right from the warning
- **keep the Mac awake** until you turn it off, or for 1–2 hours
- **drop files on a shelf** — drag files onto the notch, then drag them somewhere else later
- see the battery's **time to full** while charging

Swipe sideways with two fingers (trackpad or Magic Mouse) for the other pages, and choose which page the
notch opens on:

<table>
  <tr>
    <td width="50%"><img src="docs/images/notch-clipboard.png" alt="Searchable clipboard history page"></td>
    <td width="50%"><img src="docs/images/notch-ai.png" alt="Claude Code and Codex limits page"></td>
  </tr>
  <tr>
    <td><b>Clipboard history</b> — the last 20 things you copied, searchable (accents and case ignored),
    click to copy again. Kept across restarts, or in memory only if you prefer; passwords from password
    managers are skipped.</td>
    <td><b>Claude Code and Codex</b> — how much of the 5-hour and 7-day limits is used, when they reset,
    and today's tokens. Codex is read straight from its logs; Claude Code's limits come through its
    statusLine, and Tacho can run alongside a statusLine you already have.</td>
  </tr>
</table>

## Know how hot it's running

CPU temperature measured on the chip, each fan's speed, load per core — with plain labels like
**Cool / Warm / Hot** and **Quiet / Medium / Loud** instead of bare numbers.

<p align="center">
  <img src="docs/images/window-cpu.png" alt="CPU window: load, temperature, per-core load, GPU, fans" width="85%">
</p>

## Battery and charging, watt by watt

How many watts the Mac draws, how much is going into the battery, how long until it's full, and how
strong the charger is. Along with battery health, cycle count, and the batteries of your mouse,
keyboard and AirPods.

<p align="center">
  <img src="docs/images/window-battery.png" alt="Battery window: power, battery health, charger" width="85%">
</p>

## The whole picture on one screen

<p align="center">
  <img src="docs/images/window-overview.png" alt="Overview window, light appearance" width="85%">
</p>

Light and dark, following macOS. **24-hour history** lets you look back at CPU, temperature, memory,
network and battery, and the **Processes** tab lists everything that's running.

## English · Tiếng Việt · Русский

Switch languages in Settings; it applies at once.

<p align="center">
  <img src="docs/images/languages.png" alt="The same CPU panel in Vietnamese, English and Russian" width="100%">
</p>

## And more

- **Timely alerts** — a hot CPU, low battery, a full battery, low accessory batteries, a nearly full
  disk, no Internet; each can be turned off
- **Open at login** — one switch in Settings; it starts quietly in the menu bar without opening a window
- **Updates itself** — Tacho tells you when there's a new version; one click installs it
- **Light** — about a 3 MB download and around 2% CPU in the background; panels and pages only do work
  while you look at them
- **Private** — every reading comes from the Mac itself. Tacho only goes online to check the
  connection and look for updates, and both can be turned off. Calendar, clipboard, Docker,
  Kubernetes and the Claude Code and Codex logs are read on the Mac and never sent anywhere
- **Your way** — choose which items show in the menu bar, turn graphs on or off, hide the Dock icon,
  change how often it updates; each notch feature has its own switch

## Install

1. Download [**Tacho.dmg**](https://github.com/hieupnvmg/Tacho/releases/latest/download/Tacho.dmg)
2. Open it and drag **Tacho** into **Applications**
3. The first time: **right-click Tacho → Open** (or **System Settings → Privacy & Security → Open Anyway**)

Or install with Homebrew:

```bash
brew tap hieupnvmg/tacho
brew trust hieupnvmg/tacho
brew install --cask tacho
```

From then on Tacho updates itself. The notch features are under **Settings → Notch**, the runner and
the Docker/Kubernetes item under **Settings → Display**. A few ask for permission when you turn them on:

- **Accessibility** — so the play and skip buttons can send media keys
- **Calendar** — for meeting reminders
- **Claude Code** — click **Connect Claude Code** so Tacho becomes its statusLine and can read the
  limits (keeping any statusLine you already have); they update when you use `claude` in a terminal.
  Codex needs nothing

## For the curious

Tacho's own binary answers a few questions from the terminal
(`/Applications/Tacho.app/Contents/MacOS/Tacho …`):

| | |
|---|---|
| `--dump` | every reading, once |
| `--notch-demo` | plays each notch state, for a look or a recording |
| `--notch-info` | where the notch panel sits, and the call it sees |
| `--ai-usage` | Claude Code and Codex usage as the AI page reads it |
| `--network-info` | VPN interfaces and the apps using the network |
| `--infra-info` | Docker and Kubernetes as the menu bar item sees them |
| `--claude-connect` / `--claude-disconnect` | the Settings button, for scripts |

## Credits

The menu bar runners and the way they're played come from
[RunCat Neo](https://github.com/runcat-dev/RunCatNeo), under the Apache License 2.0
(see [`Assets/Runners/NOTICE`](Assets/Runners/NOTICE)).

---

<sub>Want to build it yourself or contribute? See [how Tacho works](docs/HOW-IT-WORKS.md) (in Vietnamese).</sub>
