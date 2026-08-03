<img src="icon.png" alt="" width="128" align="right">

# Battery Limiter

A menu bar app for Apple Silicon Macs that stops charging at 80/85/90/95%, so
a Mac that lives on AC power doesn't sit pinned at 100% all day. Lithium-ion
cells age faster the more time they spend near a full charge, and this is the
simplest lever on that.

> **Read this before installing.** macOS has no public API for capping charge.
> This does what AlDente and BatFi do: it writes *undocumented* SMC (System
> Management Controller) keys from a small root daemon. Apple can change or
> remove those keys in any macOS update — it has happened before, silently.
> The app is also unsigned (no paid Developer account). If either of those is
> a problem for you, don't install it. Nothing here is destructive and there's
> a documented [recovery path](#if-charging-gets-stuck), but you should know
> what you're running.

## Requirements

- Apple Silicon Mac (M1 or later). No Intel support.
- macOS 13 or later. Verified on macOS 14.5; see [Limitations](#limitations)
  for a known breakage on 15.5+.
- Xcode or the Command Line Tools (`xcode-select --install`) — you build it
  yourself.

## Install

```sh
git clone https://github.com/MlayKlayer/battery-limiter.git
cd battery-limiter
./Scripts/install.sh
```

That builds the app, copies it to `/Applications`, and launches it. An
outlined percentage appears in your menu bar.

Then, in the menu bar item:

1. Turn on **Limit Charging** and pick a percentage. macOS asks for your admin
   password **once** — that installs the helper daemon. Approve it.
2. Optionally set **Resume at** (see [The charge band](#the-charge-band)) and
   **Launch at Login**.

After that first prompt, changing the limit never prompts again.

Building it yourself is what keeps this painless: Gatekeeper only quarantines
files the OS *downloads*, so there's no right-click-to-Open dance and no
"unidentified developer" wall. Don't distribute the built `.app` as a
download — it's ad-hoc signed and Gatekeeper will block it on arrival.

## Usage

The menu bar shows **your cap, not the current charge** — macOS already
displays the live percentage, and a second live number next to it just reads
as something urgent. It's drawn as hollow outlined digits so it looks like the
static threshold it is, and it fades to semi-transparent whenever **Limit
Charging** is switched off.

The menu itself shows the current state and gives you:

| Control | What it does |
|---|---|
| **Limit Charging** | Master on/off. |
| **Limit to** | 80 / 85 / 90 / 95% — where charging stops. |
| **Resume at** | 60 / 65 / 70 / 75 / 77% — where charging starts again. |
| **Launch at Login** | Starts the app automatically. |
| **Remove Helper…** | Uninstalls the root daemon (asks for your password). |

The limit is enforced by the daemon, not the app, so it keeps working even if
you quit Battery Limiter. Only **Remove Helper…** or turning **Limit
Charging** off actually stops it.

### The charge band

Charging resumes at **Resume at**, not at one percent below the limit. That
gap is deliberate.

Without it the pack sits at the limit, sheds a percent, immediately charges
back, and repeats forever. The drain is real, not theoretical — measured on an
M3 Air (4522 mAh pack) capped at 80% on AC:

- **Idle:** 0 mA. The battery is completely inert; the Mac runs off the adapter.
- **Under build load:** −47 to −517 mA, losing 71 mAh in 18 minutes (~5%/h).
  A 30W adapter can't cover an M3 Air's peaks, so the battery covers the
  difference *even while plugged in*.

Be clear on what the band does and doesn't buy. It does **not** reduce total
charge throughput — if a load pulls *n* mAh out, *n* mAh goes back in whatever
the band width, so cycle count accrues about the same either way. What it buys
is a lower time-averaged state of charge (which is what drives calendar aging)
and far fewer charge-circuit transitions.

Set it near the limit (77%) to stay topped up for unplugging, or far from it
(60%) to hold the average charge lower.

## How it works

Two parts:

- **BatteryLimiter.app** — a SwiftUI `MenuBarExtra` running as your user. It
  reads battery state via the public IOKit power-source API and writes your
  settings to `/Library/Application Support/BatteryLimiter/config.json`. It
  has no special privileges.
- **`com.batterylimiter.helper`** — a LaunchDaemon running as root, because
  writing SMC keys requires root. Every 15 seconds it reads that config plus
  live battery state and sets or clears the charge inhibit (`CH0B`/`CH0C` set
  to `2` to stop charging, `0` for normal).

Splitting it this way means the app holds no privileges and the limit survives
quitting the app.

Without a paid Developer ID the usual ways to install a privileged helper
(`SMJobBless`, `SMAppService.daemon`) are unavailable — both need a Developer
ID certificate to validate the app↔helper trust relationship. So the app
installs the daemon once through a standard admin-authenticated prompt
(`osascript … with administrator privileges`), copying the helper to
`/Library/PrivilegedHelperTools/` and loading it with `launchctl bootstrap`.

There's no Xcode project by design — it's a Swift Package with two executables
and a shared library, and `Scripts/build_app.sh` assembles the `.app` by hand.
`open Package.swift` still works if you prefer Xcode.

## What's verified, and what isn't

Confirmed end-to-end on an M3 Air running macOS 14.5, limit set to 80%:

```
20:20:52  capacity=79  charging=Yes
20:21:13  capacity=80  charging=Yes
20:22:13  capacity=80  charging=No    <- inhibit applied
```

Charging stopped at the limit and capacity stopped climbing. That exercises
the privileged install, the daemon under launchd, and the SMC write itself —
the keys exist and accept writes on 14.5. The daemon's log stayed empty, so
every write succeeded.

The charge-band logic is covered by unit tests (`swift test`) rather than
hardware, since observing it live means waiting hours for the pack to drift.

**Expect ~40–80 seconds of lag** between crossing the limit and charging
actually stopping: the daemon polls every 15s, and the `IOPowerSources` API
lags `AppleSmartBattery` by several more. The overshoot is a fraction of a
percent — a latency note, not a defect.

Not verified: notification delivery, and behaviour across sleep/wake.

### Checking it yourself

```sh
ioreg -rn AppleSmartBattery | grep -i -e IsCharging -e CurrentCapacity
```

`IsCharging` should read `No` once you're at or above the limit on AC, and
`CurrentCapacity` should stop climbing.

```sh
sudo launchctl print system/com.batterylimiter.helper   # is the daemon alive?
cat /var/log/com.batterylimiter.helper.log              # any SMC errors?
```

An empty log is good news — it only gets written on failure.

## If charging gets stuck

If charging ever stays paused with no obvious cause (hard power loss before
the daemon's shutdown handler ran, or the daemon removed while inhibiting):
make sure the app is running, then turn **Limit Charging** off. The daemon
restores normal charging within one poll (~15s). There's no need to hunt for a
manual SMC reset.

## Uninstalling

1. **Remove Helper…** in the menu — resets charging to normal, stops the
   daemon, and deletes both `/Library/LaunchDaemons/com.batterylimiter.helper.plist`
   and `/Library/PrivilegedHelperTools/com.batterylimiter.helper`.
2. Quit the app and delete `/Applications/BatteryLimiter.app`.
3. If you enabled Launch at Login, remove it in System Settings → General →
   Login Items.

## Development

```sh
swift build -c release     # build
swift test                 # run the unit tests
./Scripts/build_app.sh     # assemble the .app without installing
```

**Rebuilding does not update an installed daemon.** The installer skips itself
whenever the LaunchDaemon plist already exists, so the old helper keeps
running. Use **Remove Helper…**, then re-enable **Limit Charging**.

## Limitations

- **Apple Silicon only.** No Intel support.
- **Undocumented mechanism.** `CH0B`/`CH0C` aren't documented by Apple; their
  semantics come from BatFi's open-source implementation. Apple can change
  them without notice, and has — a silent SMC firmware change broke AlDente on
  macOS 15.5+/Tahoe for some Macs. This project is verified on 14.5, which
  predates that. On newer macOS the keys may simply stop working; the daemon
  logs the failure and falls back to normal charging rather than doing
  anything unsafe.
- **Not notarized or Developer ID signed.** Ad-hoc signed only. Invisible if
  you build locally; blocking if you download a prebuilt copy.
  `UNUserNotificationCenter` can also fail silently for an ad-hoc-signed app
  outside `/Applications`, which is why the installer puts it there. If you
  move the app afterward and had Launch at Login on, toggle it off and back on
  — the old path was recorded.
- **No sleep-transition handling.** The daemon only acts while it can read
  battery state every 15s. A charge crossing the limit while the machine is
  fully asleep may take up to ~15s after wake to correct.

## Prior art

[AlDente](https://github.com/davidwernhart/AlDente) and
[BatFi](https://github.com/rurza/BatFi) are both more featureful and more
battle-tested than this. Use them if you want sleep handling, calibration
cycles, or a signed binary. This exists as a minimal, readable implementation
of just the charge cap.

## License

MIT — see [LICENSE](LICENSE). Includes code adapted from
[SMCKit](https://github.com/beltex/SMCKit) (MIT).
