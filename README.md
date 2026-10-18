# MatiBar

**A fully custom MacBook Pro Touch Bar, written from scratch in Objective-C.**

MatiBar replaces Apple's Control Strip with your own full-width Touch Bar: a live
animated battery with real-time power draw, a Spotify / Apple Music player with a
draggable timeline, system volume and brightness controls, an animated day & weather
view, and a one-tap button to open Claude. No third-party frameworks, no dependencies —
just the system APIs that Apple's own Touch Bar uses.

> Built for Apple Silicon MacBook Pro (13"/15"/16") with a Touch Bar, on modern macOS.
> MTMR and the other old tools don't work on current macOS anymore — this one does,
> because it talks to the Touch Bar APIs that are still alive today.

---

## Default view — battery

![default](screenshots/default.png)

- **Live animated battery.** The fill colour and animation tell you the state at a glance:
  - 🟢 **Green + forward sweep** — charging
  - ⚪ **White + reverse sweep** — on battery (draining)
  - 🟡 **Yellow** — Low Power Mode
  - 🔴 **Red** — battery below 20%
- **Real-time power draw in watts**, read from the SoC via `IOReport` (works plugged in
  or on battery, even at the 80% charge limit). The drain animation speeds up the more
  power you use.
- The colour switches the instant you plug in — synced to the charging chime, not polled.

## Audio view — tap the speaker button

![audio](screenshots/audio.png)

- **Album art + track / artist**, pulled live from Spotify or Apple Music. Tap it to
  bring the player window to the front.
- **Thin draggable timeline** — scrub to any point in the song with your finger.
- **Play / pause / previous / next.**
- **10-bar volume** controlling the **system master volume** — tap a bar, drag across
  them, or use the speaker − / + buttons.

## Brightness view — tap the sun button inside audio

![brightness](screenshots/brightness.png)

- **10-bar display brightness** (`DisplayServices`) — tap, drag, or use the sun − / +
  buttons. A safety floor keeps the screen from ever going fully black.

## Day & weather view — tap the clock

![weather](screenshots/weather.png)

![weather at night](screenshots/weather-night.png)

- **Full-day timeline** (00:00 → 23:59) with hourly tick marks, and the **sun's arc drawn
  only across the daylight hours** (sunrise → sunset). A marker rides the arc at the
  current time — a **sun** by day, a **real-phase moon** by night (hemisphere-aware).
- **Animated background that matches the real conditions and time of day** — clear blue
  day, starry night, drifting clouds, falling rain, snow, fog, and storms with lightning.
- **Rain icons** appear over upcoming hours with a high chance of rain.
- Current **temperature, condition, date, and the day's high / low**. Weather is from the
  free [Open-Meteo](https://open-meteo.com) API with IP-based location — no key, works
  anywhere.

The **Claude** and **audio** buttons stay pinned to the right at all times — opening a
panel only changes what's to their left, so they never move.

---

## Install

Requires **Xcode Command Line Tools** (`xcode-select --install`).

```bash
git clone https://github.com/RoccoDeDog/MatiBar.git
cd MatiBar
./install.sh
```

This builds `MatiBar.app`, installs it to `/Applications`, switches the Touch Bar to
full-width mode, and sets it to launch at login.

The first time you use the audio controls, macOS asks permission to control
Spotify / Music (**Automation**) — approve it so playback works.

**Uninstall** (restores the normal Apple Touch Bar):

```bash
./uninstall.sh
```

For quick dev runs without installing: `./start.sh` and `./stop.sh`.

---

## How it works

MatiBar presents a **system-modal Touch Bar** across the whole bar using the private
`DFRFoundation` framework (`DFRElementSetControlStripPresenceForIdentifier`,
`presentSystemModalTouchBar:placement:…`) — the same mechanism Apple's Control Strip
uses. On top of that:

- **Battery / charging** — `IOKit` (`IOPowerSources`, `AppleSmartBattery`) + a power-source
  change notification for instant updates.
- **Live power (watts)** — `IOReport` "Energy Model" channels (CPU + GPU + ANE + DRAM).
- **Brightness** — `DisplayServices` (`DisplayServicesGet/SetBrightness`).
- **Media** — AppleScript to Spotify / Apple Music for metadata, scrubbing and transport.
  System volume via the standard `set volume` command.
- **Weather** — Open-Meteo (forecast + hourly rain) with IP-based geolocation; the sky,
  timeline, and moon phase are all drawn from scratch — no weather SDK or entitlement.

Everything is one file: [`matibar.m`](matibar.m). The [`examples/`](examples) folder has a
minimal "hello world" Touch Bar button and a demo that plays looping video on the bar.

See [GUIDE.md](GUIDE.md) for the full user guide (battery colour legend, what the watts
mean, controls).

---

## Security & privacy

- **Runs 100% locally.** No network connections, no server, no telemetry, nothing phones
  home — so there's nothing to attack remotely.
- **No data collected or stored.** It only reads your own battery, brightness and the
  track playing in your own music app, and draws them on your own Touch Bar.
- **Permissions you grant stay on your Mac:** Automation (to control Spotify / Music) is
  the only one it asks for, and macOS shows you the prompt.
- **Open source** — every line is in this repo for you to read before you run it.

---

## Notes

- Apple restricted the system "Now Playing" info (`MediaRemote`) for unsigned apps on
  recent macOS, so rich metadata (art / title / scrubber) works for **Spotify and Apple
  Music**; browser audio (YouTube, etc.) can't be read.
- Full-width mode hides Apple's Control Strip while MatiBar runs. `uninstall.sh` puts it
  back. Brightness and volume live inside MatiBar's audio panel instead.

## License

MIT — see [LICENSE](LICENSE).

---

*Designed and built collaboratively with [Claude Code](https://claude.com/claude-code).*
