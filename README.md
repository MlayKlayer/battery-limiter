# Battery Limiter

A menu bar app for Apple Silicon Macs that caps battery charging at 80/85/90/95%,
to keep the battery healthier over years of daily use on AC power.

There is no public Apple API for this. It works the same way AlDente and BatFi
do: it writes undocumented SMC (System Management Controller) keys that tell
the hardware to stop charging. This is unofficial and reverse-engineered —
see **Limitations** below.

## What it does

- Menu bar item showing live battery percentage.
- Toggle to turn charge limiting on/off, a picker for 80/85/90/95%, and a
  "Resume at" picker (60/65/70/75/77%) for the bottom of the charge band.
- While plugged in and above the chosen limit, charging is paused (the SMC
  `CH0B`/`CH0C` keys are set to inhibit charging). On battery, or with
  limiting off, charging is normal.
- **Charging resumes at "Resume at", not at limit-minus-one.** Without that
  deadband the pack would sit at the limit, lose a percent to self-discharge
  or a load peak the adapter couldn't cover, charge straight back, and repeat
  — a permanent 1% sawtooth. Each of those round trips is ~1% of a charge
  cycle. The band converts that into a rare, shallow dip. Set it close to the
  limit (77%) to stay topped up, or far from it (60%) for the fewest cycles.
- A notification when the cap is first reached on a charge cycle.
- Optional "Launch at Login".

## How it's built

Two parts:

- **BatteryLimiter.app** — the SwiftUI menu bar app (`MenuBarExtra`). Runs as
  your user. Reads battery state via the public `IOKit` power-source API and
  writes your chosen settings to `/Library/Application Support/BatteryLimiter/config.json`.
- **A privileged helper daemon** (`com.batterylimiter.helper`) — a tiny
  LaunchDaemon that runs as root, since writing SMC keys requires root. It
  polls that same config file plus the live battery state every 15 seconds
  and applies (or removes) the charge inhibit — independent of whether the
  app is even running, so the limit keeps working if you quit the app.

There's no paid Apple Developer account here, which rules out the "proper"
ways apps like this normally install a privileged helper
(`SMJobBless`/`SMAppService.daemon`, both of which require a Developer ID
certificate to validate the trust relationship between the app and the
helper). Instead, the app installs the daemon once via a single
admin-authenticated prompt (macOS's standard "Battery Limiter wants to make
changes" dialog, via `osascript ... with administrator privileges`), which
copies the helper to `/Library/PrivilegedHelperTools/` and loads it as a
LaunchDaemon with `launchctl bootstrap`. After that one prompt, turning the
limit on/off or changing the percentage never prompts again — it's just a
file write the daemon picks up on its next poll.

There is intentionally no Xcode project — this is a Swift Package with two
executable targets (`BatteryLimiter`, `BatteryLimiterHelper`) and one shared
library (`BatteryLimiterShared`). `Scripts/build_app.sh` builds it and
assembles the `.app` bundle by hand. Xcode can still open `Package.swift`
directly if you'd rather build/debug there.

## Install

```sh
./Scripts/install.sh
```

Builds the app, copies it to `/Applications`, and launches it. Look for the
battery percentage in your menu bar. Then:

1. Click the menu bar item, turn on **Limit Charging**, and pick a
   percentage. The first time you enable it, macOS prompts for your admin
   password once — that installs the helper daemon. Approve it.
2. Pick **Launch at Login** if you want it to start automatically.

That's the whole setup. Because you build it locally, Gatekeeper never
quarantines it, so there's no right-click-to-Open dance — the quarantine flag
is only set on files the OS downloads.

**Always launch the `/Applications` copy.** `Scripts/install.sh` leaves the
build output at the repo root too; if you launch that one,
`SMAppService.mainApp.register()` records the wrong path and Launch at Login
will point at a copy you may later delete.

## Building without installing

```sh
./Scripts/build_app.sh
```

This runs `swift build -c release`, assembles `BatteryLimiter.app`, and
ad-hoc signs it (`codesign --sign -`) — required for `SMAppService.mainApp`
login-item registration to work at all, even without a Developer ID.

**If you've already installed the helper and then rebuild**, the new helper
binary is *not* picked up automatically — `install()` is skipped whenever the
LaunchDaemon plist already exists, so the old daemon keeps running. Use
**Remove Helper…** in the menu, then turn **Limit Charging** back on to
reinstall.

To build/run from Xcode instead: `open Package.swift`, select the
`BatteryLimiter` scheme, and Run. (The helper daemon target still needs to be
built and bundled via the script above to actually install — Xcode's Run
button only launches the menu bar app on its own.)

## What's been verified

End-to-end on an M-series Mac running macOS 14.5, with the helper installed
and the limit set to 80%:

```
20:20:52  capacity=79  charging=Yes
20:21:13  capacity=80  charging=Yes
20:22:13  capacity=80  charging=No    <- inhibit applied
```

Charging stopped at the limit and the battery stopped climbing. That covers
the privileged helper install, the daemon running under launchd, the SMC
write itself (the `CH0B`/`CH0C` keys exist and accept writes on 14.5), and
the menu's Toggle/Picker. `/var/log/com.batterylimiter.helper.log` stayed
empty throughout — every SMC write succeeded.

Also verified: it compiles, the `.app` is validly ad-hoc signed, the menu bar
shows a live correct percentage, and the helper's failure-log throttle emits
one line per failure run rather than one per poll.

**Expect ~40–80 seconds of lag** between crossing the limit and charging
actually stopping — the daemon polls every 15s, and the `IOPowerSources` API
it reads lags `AppleSmartBattery` by a further several seconds. The overshoot
is a fraction of a percent, so this is a latency note, not a defect.

Still unverified: notification delivery (it failed when run ad-hoc from
outside `/Applications`; untested from `/Applications`), and behaviour across
sleep/wake.

## Confirming the limit is applied on your machine

```sh
ioreg -rn AppleSmartBattery | grep -i -e IsCharging -e CurrentCapacity -e MaxCapacity
```

`IsCharging` should read `No` once you're at/above the limit with the charger
connected, and `CurrentCapacity` should stop climbing. Unplug and replug, or
drop below the limit, and charging should resume.

To check the daemon itself is alive:

```sh
sudo launchctl print system/com.batterylimiter.helper
```

Logs (if anything goes wrong) are at `/var/log/com.batterylimiter.helper.log`.

## Recovery

If charging ever ends up stuck paused with no obvious cause (e.g. hard power
loss before the daemon's shutdown handler ran, or the daemon got removed
while it was actively inhibiting), the reliable fix is: make sure the app is
running, confirm the helper is installed (see above), and turn **Limit
Charging** off. The daemon writes the normal-charging state back within one
poll cycle (~15s) — you don't need to hunt for a manual SMC reset.

## Uninstalling

Use **Remove Helper…** in the menu, which runs another admin-authenticated
script that terminates the daemon, resets charging to normal first, then
deletes `/Library/LaunchDaemons/com.batterylimiter.helper.plist` and
`/Library/PrivilegedHelperTools/com.batterylimiter.helper`. Then quit the app,
delete `/Applications/BatteryLimiter.app`, and — if you enabled it — remove it
from Login Items.

## Limitations

- **Apple Silicon only.** No Intel support (per the M-series-only scope of
  this project).
- **Unofficial mechanism.** `CH0B`/`CH0C` are undocumented SMC keys, verified
  against BatFi's current (2026) open-source implementation
  (github.com/rurza/BatFi) rather than any Apple documentation, because none
  exists. Apple can change or remove them in any macOS update without notice
  — there's a known case of exactly this breaking AlDente on macOS 15.5+ /
  Tahoe for some Macs (a silent SMC firmware change). This machine is on
  macOS 14.5 (Darwin 23.5.0), which predates that breakage, so the keys
  should work here as implemented.
- **Not notarized / not signed with a Developer ID.** Ad-hoc signed only.
  This is invisible as long as you build locally (nothing quarantines it),
  but you can't hand the `.app` to someone else as a download without
  Gatekeeper blocking it. `UNUserNotificationCenter` authorization can also
  fail silently for an ad-hoc-signed app run from outside `/Applications` —
  which is why `Scripts/install.sh` puts it there. If you move the app
  afterward and had **Launch at Login** on, toggle it off and back on —
  `SMAppService.mainApp.register()` recorded the old path.
- **No lid-closed/sleep handling.** The daemon only acts while it can read a
  battery/AC state (every 15s); it doesn't have BatFi's sleep-transition
  logic. This is fine for the "cap while I'm using it plugged in" use case
  this was built for, but a charge that crosses the limit while the display
  is fully asleep may take up to ~15s after wake to correct.
