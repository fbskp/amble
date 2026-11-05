# Pad compatibility

Amble talks to walking pads over the standard Bluetooth Fitness Machine Service (FTMS). It has been verified with **one** pad model so far. Other pads that follow the standard may work fully or partly; pads with their own protocol will not work.

## Status

| Pad | Status | Notes | Reported by |
|---|---|---|---|
| Sportstech WalkMate (advertises as "WalkMate-…", module FITHOME JJ-BT2-DL) | Verified | Everything works: start, stop, pause, speed in 0.1 km/h steps. The pad has no step counter, so Amble estimates steps from distance. | maintainer |

Status meanings:

- **Verified**: tested by a person on a real pad, all features work.
- **Partial**: works, but something is missing or wrong (say what in the notes).
- **Not working**: connects but cannot be used, or does not connect.

## Known not to work

- **Kingsmith WalkingPad (A1, R1, R2 and similar)**: uses its own Bluetooth protocol, not FTMS. Amble would need a separate driver.
- Any pad that does not offer the Fitness Machine Service. Amble tells you when it connects to such a device.

## How to report your pad

1. Connect your pad in Amble.
2. Open **Settings > Pad compatibility** and tap **Copy report**.
3. [Open a compatibility report](../../issues/new?template=compatibility.md) and paste the report.
4. Say what worked: start, stop, pause, speed up and down, and whether distance and time looked right.

The report contains only the pad's name and capabilities, your iOS version and the Amble version.

## Safety

Amble controls a physical machine. With an untested pad it may behave unexpectedly, for example by changing the speed on its own. Stay close, keep the belt clear when you start, and know how to stop the pad without the app (remote or power switch).
