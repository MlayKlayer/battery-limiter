# The charge-limit keys are gone on macOS 15.7.9 / Mac15,12

Found while fixing the red "Remove Helper…" text on 2026-08-22. Unrelated to
that bug, and much worse: **the cap is not being applied at all.**

## What happens

`/var/log/com.batterylimiter.helper.log`, every line of it:

    17:59:26  SMC write failed, resetting to normal charging: keyNotFound
    18:12:16  sleep: 100% on AC, applied=normal, adapter cut cleared=false
    18:12:16  sleep: could not clear the adapter cut -- the Mac may sleep on battery power
    18:15:58  wake: 100% on AC, re-asserting
    18:24:39  SMC write failed, resetting to normal charging: keyNotFound
    18:24:47  SMC write failed, resetting to normal charging: keyNotFound

`ChargeControl.apply` throws `keyNotFound` on every path, so `lastAction`
never leaves `.normal` and charging is never inhibited.

The log looks short because `loggedFailure` (ChargeController.swift:275)
deliberately logs once per failure run. Silence after 18:24:47 is not recovery.

## Cause

`CH0B`, `CH0C` and `CH0I` are not present in this machine's SMC key table
(macOS 15.7.9, Mac15,12). Whether they were ever present on *this* Mac is
not something this session verified -- the -827 mA CH0I measurement in
SMC.swift is a note from an earlier session, not an observation made here.

Enumerated all 1719 keys via `kSMCGetKeyFromIndex` on `Mac15,12`,
macOS 15.7.9, M3 MacBook Air. Every `CH*` key present:

    ACLC ACLM CH0D CH0E CH0H CH0J CH0R CH0V CHA1 CHA2 CHAI CHAS CHBI CHBV
    CHCC CHCE CHCF CHCR CHDB CHFS CHHC CHHV CHHW CHI1 CHI2 CHIB CHIC CHIE
    CHIF CHIL CHIM CHIO CHIS CHLS CHLT CHM2 CHNC CHND CHNI CHOC CHPS CHRT
    CHSC CHSE CHSL CHST CHSW CHTC CHTE CHTL CHTM CHTU

B, C and I are absent while their neighbours D/E/H/J/R/V are present.
`kSMCGetKeyInfo` on each returns SMC result 132 (`kSMCKeyNotFound`).

Ruled out, each by direct test rather than reasoning:

- **Not a privilege gate.** The daemon gets 132 as root; the probe gets 132
  as uid 501. Same code.
- **Not the user client type.** `IOServiceOpen` types 0-4 all open, all
  return the same 1719-key table.
- **Not adapter-dependent.** Re-probed with a 35 W adapter attached and the
  pack at 100% ("charged", on AC). Identical result -- this was the last
  benign explanation and it died.
- **Not the macOS update being blamed on circumstance.** macOS 15.7.9
  installed 17:59; the log's first line is 17:59:25. The daemon's first act
  after the reboot failed.

The pack reaching 100% is *not* evidence on its own -- per the user, Limit
Charging was switched off manually before the update, which would account
for it. (Unverified: config.json's only timestamp is 18:24:46, so there is
no record of its pre-update state.) The
evidence is the `keyNotFound`, which happens either way: with the limiter
off the daemon still writes the same three keys with value 0 to *release*
the cap, and that write fails too.

## The replacement

Newer Apple Silicon under Sequoia uses **`CHTE`** (and `CHIE`) instead of
CH0B/CH0C. Both are present here and both are writable:

    CHTE  size=4  type=ui32  attr=0xd4  reads 0,0,0,0
    CHIE  size=1  type=hex_  attr=0xd4  reads 0
    CH0J  size=1  type=ui8   attr=0xd4  reads 0

`attr=0xd4` is the same attribute the other writable-privileged keys carry.

Values taken from OpenDente's helper (`OpenDenteHelper/HelperDelegate.swift`),
which drives both sets:

| action           | legacy                  | modern              |
| ---------------- | ----------------------- | ------------------- |
| resume charging  | CH0B=0x00, CH0C=0x00    | CHTE=`00 00 00 00`  |
| inhibit charging | CH0B=0x02, CH0C=0x02    | CHTE=`01 00 00 00`  |
| cut adapter      | CH0I=0x01               | CHIE=**0x08**       |
| restore adapter  | CH0I=0x00               | CHIE=0x00           |

CHIE's cut value is 8, not the 1 CH0I takes. Guessing by analogy would have
been wrong, on the key whose stuck state flattens the pack.

## Fixed

`ChargeControl` now carries both sets as `KeySet.legacy` / `KeySet.modern`
and probes at open -- `SMC.keyExists("CHTE")` decides. Probed rather than
keyed off model or OS version, since the changeover lines up cleanly with
neither.

`SMC.writeUInt8` became `SMC.write(_:value:size:)`: CHTE is a ui32 where the
others are single bytes, and since the SMC is little-endian and every value
in the table above fits in the low byte, one call with a different `size`
covers both.

Two things make the next silent failure loud instead:

- the daemon logs `charge keys: <set>` at startup
- `BatteryLimiterHelper --check` prints the detected set and the bytes each
  action would write, writes nothing, and needs no root:

      key set: CHTE/CHIE
        normal    CHTE = 0 (4B), CHIE = 0
        inhibit   CHTE = 1 (4B), CHIE = 0
        discharge CHTE = 1 (4B), CHIE = 8

**Not done:** OpenDente reads the key back after writing to confirm it took.
Worth adding if a write ever succeeds without the cap engaging.

Note also: nothing in the app updates an already-installed helper.
`Scripts/install.sh` only copies the app bundle, and
`HelperInstaller.isInstalled` checks only that the plist exists, so
`setEnabled(true)` will not reinstall the binary. Any change here reaches
the running daemon only via Remove Helper… then re-enable.

## Sources

- https://github.com/killerk3emstar/OpenDente -- probes both key sets at
  startup and uses whichever responds; names CH0B/CH0C (M1-M3) vs
  CHTE/CHIE (≈2023+, Sequoia/Tahoe)
- https://github.com/charlie0129/batt
- https://github.com/rurza/BatFi -- the reference already cited in SMC.swift:138
